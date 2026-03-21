import Foundation
import Security
import CommonCrypto
import SQLite3
import WebKit

// MARK: - ChromeCookieImporter

final class ChromeCookieImporter: @unchecked Sendable {

    static let shared = ChromeCookieImporter()

    // MARK: - Error types

    enum ImportError: Error, LocalizedError {
        case chromeNotInstalled
        case keychainAccessDenied
        case keychainError(OSStatus)
        case databaseOpenFailed(String)
        case decryptionFailed
        case noProfile(String)

        var errorDescription: String? {
            switch self {
            case .chromeNotInstalled:
                return String(localized: "browser.import.error.chromeNotInstalled", defaultValue: "Google Chrome is not installed or its data directory is missing.")
            case .keychainAccessDenied:
                return String(localized: "browser.import.error.keychainAccessDenied", defaultValue: "Access to the Chrome Safe Storage keychain item was denied.")
            case .keychainError(let status):
                return String(localized: "browser.import.error.keychainError", defaultValue: "Keychain error: \(status)")
            case .databaseOpenFailed(let reason):
                return String(localized: "browser.import.error.databaseOpenFailed", defaultValue: "Failed to open Chrome cookie database: \(reason)")
            case .decryptionFailed:
                return String(localized: "browser.import.error.decryptionFailed", defaultValue: "Failed to decrypt Chrome cookie values.")
            case .noProfile(let name):
                return String(localized: "browser.import.error.noProfile", defaultValue: "Chrome profile not found: \(name)")
            }
        }
    }

    // MARK: - Import result

    struct ImportResult: Sendable {
        let cookieCount: Int
        let error: ImportError?
    }

    // MARK: - Constants

    private static let chromeAppSupportPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Google/Chrome"
    }()

    private let importQueue = DispatchQueue(
        label: "com.cmux.chrome-cookie-import",
        qos: .userInitiated
    )

    /// Seconds between 1601-01-01 and 1970-01-01 (Unix epoch).
    private static let chromeEpochOffset: Int64 = 11_644_473_600

    /// Minimum interval between automatic re-imports (5 minutes).
    private static let autoReimportInterval: TimeInterval = 300

    /// Guards access to `lastImportTime` and `importInFlight` for thread safety.
    private let lock = NSLock()

    /// Timestamp of last successful import.
    private var lastImportTime: Date?

    /// Whether an import is currently in progress (prevents duplicate concurrent imports).
    private var importInFlight = false

    private init() {}

    /// Triggers a cookie re-import if enough time has passed since the last one.
    /// Called when a new browser tab is opened. No-op if auto-import is disabled,
    /// Chrome is not installed, or the throttle interval hasn't elapsed.
    static func importIfNeeded() {
        guard UserDefaults.standard.bool(forKey: ChromeCookieSettings.autoImportEnabledKey),
              isChromeInstalled else { return }

        let shouldImport: Bool = shared.lock.withLock {
            guard !shared.importInFlight else { return false }
            let now = Date()
            if let lastImport = shared.lastImportTime,
               now.timeIntervalSince(lastImport) < autoReimportInterval {
                return false
            }
            shared.importInFlight = true
            return true
        }
        guard shouldImport else { return }

        importCookies { _ in
            shared.lock.withLock {
                shared.importInFlight = false
            }
        }
    }

    // MARK: - Step 1: Chrome profile discovery

    static var isChromeInstalled: Bool {
        FileManager.default.fileExists(atPath: chromeAppSupportPath)
    }

    /// Scans Chrome's data directory for profile subdirectories.
    /// Returns a sorted list with "Default" first, then alphabetical by display name.
    static func availableProfiles() -> [(directory: String, displayName: String)] {
        let basePath = chromeAppSupportPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: basePath) else { return [] }

        var profiles: [(directory: String, displayName: String)] = []

        guard let contents = try? fm.contentsOfDirectory(atPath: basePath) else {
            return []
        }

        for entry in contents {
            let entryPath = "\(basePath)/\(entry)"

            // Chrome profiles are either "Default" or "Profile N"
            guard entry == "Default" || entry.hasPrefix("Profile ") else { continue }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entryPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            // Check that a Cookies file exists in the profile directory
            let cookiesPath = "\(entryPath)/Cookies"
            guard fm.fileExists(atPath: cookiesPath) else { continue }

            let displayName = readProfileDisplayName(at: entryPath) ?? entry
            profiles.append((directory: entry, displayName: displayName))
        }

        // Sort: "Default" first, then alphabetical by display name
        profiles.sort { lhs, rhs in
            if lhs.directory == "Default" && rhs.directory != "Default" { return true }
            if rhs.directory == "Default" { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return profiles
    }

    /// Reads the profile display name from Chrome's Preferences JSON.
    private static func readProfileDisplayName(at profilePath: String) -> String? {
        let prefsPath = "\(profilePath)/Preferences"
        guard let data = FileManager.default.contents(atPath: prefsPath) else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let name = profile["name"] as? String,
              !name.isEmpty
        else {
            return nil
        }

        return name
    }

    /// Returns the path to the Cookies SQLite database for a given profile directory name.
    private static func cookieDBPath(profile: String) -> String {
        "\(Self.chromeAppSupportPath)/\(profile)/Cookies"
    }

    // MARK: - Step 2: Keychain access

    /// Reads the "Chrome Safe Storage" password from macOS Keychain.
    private static func readChromeKeychainPassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let password = String(data: data, encoding: .utf8)
            else {
                throw ImportError.keychainError(status)
            }
            return password

        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            throw ImportError.keychainAccessDenied

        default:
            throw ImportError.keychainError(status)
        }
    }

    // MARK: - Step 3: AES-128-CBC decryption

    /// Derives a 16-byte AES key from the Chrome keychain password using PBKDF2.
    private static func deriveKey(fromPassword password: String) -> [UInt8] {
        let salt = Array("saltysalt".utf8)
        let iterations: UInt32 = 1003
        let keyLength = 16

        var derivedKey = [UInt8](repeating: 0, count: keyLength)

        password.withCString { passwordPtr in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordPtr,
                strlen(passwordPtr),
                salt,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                iterations,
                &derivedKey,
                keyLength
            )
        }

        return derivedKey
    }

    /// Decrypts a Chrome cookie value that uses the `v10` encryption format.
    ///
    /// Chrome cookie values are encrypted with AES-128-CBC:
    /// - First 3 bytes: version tag (`v10`)
    /// - IV: 16 bytes of space characters (0x20)
    /// - Remaining bytes: AES-128-CBC encrypted data with PKCS7 padding
    ///
    /// Modern Chrome (v80+) prepends a 32-byte hash to the plaintext before encryption.
    /// After decrypting, we strip these 32 bytes to get the actual cookie value.
    private static func decryptCookieValue(_ encryptedData: Data, key: [UInt8]) -> String? {
        // Must have at least the 3-byte "v10" prefix plus some cipher data
        guard encryptedData.count > 3 else { return nil }

        let prefix = encryptedData.prefix(3)
        guard String(data: prefix, encoding: .utf8) == "v10" else { return nil }

        let ciphertext = encryptedData.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: 16)

        // AES-128-CBC output buffer (ciphertext length + one block for padding)
        let bufferSize = ciphertext.count + kCCBlockSizeAES128
        var decryptedBytes = [UInt8](repeating: 0, count: bufferSize)
        var decryptedLength = 0

        let status = ciphertext.withUnsafeBytes { ciphertextPtr in
            CCCrypt(
                CCOperation(kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding),
                key,
                key.count,
                iv,
                ciphertextPtr.baseAddress,
                ciphertext.count,
                &decryptedBytes,
                bufferSize,
                &decryptedLength
            )
        }

        guard status == kCCSuccess, decryptedLength > 0 else { return nil }

        let decrypted = Array(decryptedBytes.prefix(decryptedLength))

        // Modern Chrome prepends a 32-byte hash/integrity prefix to the plaintext.
        // Strip it to get the actual cookie value. If the decrypted data is <= 32 bytes,
        // try interpreting the whole thing as the value (older Chrome format).
        let valueBytes: ArraySlice<UInt8>
        if decrypted.count > 32 {
            valueBytes = decrypted.dropFirst(32)
        } else {
            valueBytes = decrypted[...]
        }

        return String(bytes: valueBytes, encoding: .utf8)
    }

    // MARK: - Step 4: SQLite reading

    /// Reads and decrypts cookies from Chrome's SQLite database.
    private static func readCookies(profile: String, key: [UInt8]) throws -> [HTTPCookie] {
        let dbPath = cookieDBPath(profile: profile)
        let fm = FileManager.default

        guard fm.fileExists(atPath: dbPath) else {
            throw ImportError.noProfile(profile)
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY
        let openStatus = sqlite3_open_v2(dbPath, &db, flags, nil)

        guard openStatus == SQLITE_OK, let db = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw ImportError.databaseOpenFailed(message)
        }

        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 1000)

        var cookies: [HTTPCookie] = []

        let query = """
            SELECT host_key, name, path, encrypted_value, is_secure, is_httponly, expires_utc, value
            FROM cookies
            WHERE expires_utc > 0 OR is_persistent = 1
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw ImportError.databaseOpenFailed(message)
        }

        defer { sqlite3_finalize(stmt) }

        let now = currentChromeTimestamp()

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let hostKeyCStr = sqlite3_column_text(stmt, 0),
                  let nameCStr = sqlite3_column_text(stmt, 1),
                  let pathCStr = sqlite3_column_text(stmt, 2)
            else {
                continue
            }

            let hostKey = String(cString: hostKeyCStr)
            let name = String(cString: nameCStr)
            let path = String(cString: pathCStr)

            // Skip expired cookies
            let expiresUtc = sqlite3_column_int64(stmt, 6)
            if expiresUtc > 0 && expiresUtc < now {
                continue
            }

            // Prefer encrypted_value; fall back to plaintext value column
            let blobPtr = sqlite3_column_blob(stmt, 3)
            let blobLen = sqlite3_column_bytes(stmt, 3)

            var value: String?
            if let blobPtr = blobPtr, blobLen > 0 {
                let encryptedData = Data(bytes: blobPtr, count: Int(blobLen))
                value = decryptCookieValue(encryptedData, key: key)
            }
            // Fall back to plaintext value column (index 7)
            if value == nil || value?.isEmpty == true {
                if let plaintextCStr = sqlite3_column_text(stmt, 7) {
                    let plaintext = String(cString: plaintextCStr)
                    if !plaintext.isEmpty {
                        value = plaintext
                    }
                }
            }
            guard let cookieValue = value, !cookieValue.isEmpty else { continue }

            let isSecure = sqlite3_column_int(stmt, 4) != 0
            let isHttpOnly = sqlite3_column_int(stmt, 5) != 0

            // Chrome stores domain cookies with a leading dot (".github.com") and
            // host-only cookies without ("github.com"). Preserve this distinction:
            // - Domain cookies: keep the leading dot so the cookie applies to subdomains.
            // - Host-only cookies: use the bare host. __Host- prefixed cookies MUST NOT
            //   have a Domain attribute at all per the cookie spec.
            let domain = hostKey

            // Convert Chrome timestamp to Unix Date
            let expiresDate: Date?
            if expiresUtc > 0 {
                let unixSeconds = TimeInterval(expiresUtc / 1_000_000) - TimeInterval(Self.chromeEpochOffset)
                expiresDate = Date(timeIntervalSince1970: unixSeconds)
            } else {
                expiresDate = nil
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .path: path,
                .name: name,
                .value: cookieValue,
                .secure: isSecure ? "TRUE" : "FALSE",
            ]

            // __Host- cookies must not have a Domain attribute.
            // For other cookies, set .domain to preserve Chrome's host/domain distinction.
            if name.hasPrefix("__Host-") {
                let scheme = isSecure ? "https" : "http"
                properties[.originURL] = "\(scheme)://\(hostKey)"
            } else {
                properties[.domain] = domain
            }

            if isHttpOnly {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "YES"
            }

            if let expiresDate = expiresDate {
                properties[.expires] = expiresDate
            }

            if let cookie = HTTPCookie(properties: properties) {
                cookies.append(cookie)
            }
        }

        return cookies
    }

    /// Returns the current time as a Chrome-format timestamp (microseconds since 1601-01-01).
    private static func currentChromeTimestamp() -> Int64 {
        let unixSeconds = Int64(Date().timeIntervalSince1970)
        return (unixSeconds + Self.chromeEpochOffset) * 1_000_000
    }

    // MARK: - Chrome history import

    /// Path to Chrome's History SQLite database for a given profile.
    private static func historyDBPath(profile: String) -> String {
        "\(chromeAppSupportPath)/\(profile)/History"
    }

    /// Reads browsing history from Chrome's History SQLite database.
    /// Copies the file (and WAL sidecars) to a temp location first because Chrome holds an exclusive lock.
    private static func readHistory(profile: String) throws -> [BrowserHistoryStore.Entry] {
        let srcPath = historyDBPath(profile: profile)
        guard FileManager.default.fileExists(atPath: srcPath) else {
            return []
        }

        // Chrome locks the History file exclusively. Copy to temp to read safely.
        // Also copy WAL sidecar files so we get the most recent data.
        let tmpBase = NSTemporaryDirectory() + "cmux-chrome-history-\(UUID().uuidString)"
        let tmpPath = tmpBase + ".db"
        defer {
            try? FileManager.default.removeItem(atPath: tmpPath)
            try? FileManager.default.removeItem(atPath: tmpPath + "-wal")
            try? FileManager.default.removeItem(atPath: tmpPath + "-shm")
        }

        do {
            try FileManager.default.copyItem(atPath: srcPath, toPath: tmpPath)
            // Best-effort copy of WAL sidecars — they may not exist
            try? FileManager.default.copyItem(atPath: srcPath + "-wal", toPath: tmpPath + "-wal")
            try? FileManager.default.copyItem(atPath: srcPath + "-shm", toPath: tmpPath + "-shm")
        } catch {
            #if DEBUG
            NSLog("[ChromeCookieImporter] failed to copy History DB: \(error)")
            #endif
            return []
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let query = """
            SELECT url, title, visit_count, typed_count, last_visit_time
            FROM urls
            WHERE hidden = 0 AND visit_count > 0
            ORDER BY last_visit_time DESC
            LIMIT 5000
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var entries: [BrowserHistoryStore.Entry] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlCStr = sqlite3_column_text(stmt, 0) else { continue }
            let urlString = String(cString: urlCStr)

            // Skip non-HTTP(S) URLs
            guard urlString.hasPrefix("http://") || urlString.hasPrefix("https://") else {
                continue
            }

            let title: String?
            if let titleCStr = sqlite3_column_text(stmt, 1) {
                let t = String(cString: titleCStr)
                title = t.isEmpty ? nil : t
            } else {
                title = nil
            }

            let visitCount = Int(sqlite3_column_int(stmt, 2))
            let typedCount = Int(sqlite3_column_int(stmt, 3))
            let lastVisitTime = sqlite3_column_int64(stmt, 4)

            // Convert Chrome timestamp to Date
            let unixSeconds = TimeInterval(lastVisitTime / 1_000_000) - TimeInterval(chromeEpochOffset)
            let lastVisited = Date(timeIntervalSince1970: unixSeconds)

            let entry = BrowserHistoryStore.Entry(
                id: UUID(),
                url: urlString,
                title: title,
                lastVisited: lastVisited,
                visitCount: visitCount,
                typedCount: typedCount
            )
            entries.append(entry)
        }

        return entries
    }

    // MARK: - Public import API

    /// Injects cookies into WKWebView and merges history. Must be called on the main thread.
    @MainActor
    private static func applyImportedData(
        cookies: [HTTPCookie],
        historyEntries: [BrowserHistoryStore.Entry],
        completion: @escaping (ImportResult) -> Void
    ) {
        // Merge Chrome history into BrowserHistoryStore
        if !historyEntries.isEmpty {
            BrowserHistoryStore.shared.mergeImportedEntries(historyEntries)
        }

        guard !cookies.isEmpty else {
            completion(ImportResult(cookieCount: 0, error: nil))
            return
        }

        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        let group = DispatchGroup()

        for cookie in cookies {
            group.enter()
            cookieStore.setCookie(cookie) {
                group.leave()
            }
        }

        group.notify(queue: .main) {
            shared.lock.withLock {
                shared.lastImportTime = Date()
            }
            completion(ImportResult(cookieCount: cookies.count, error: nil))
        }
    }

    /// Imports Chrome cookies into WKWebView's default cookie store and Chrome history
    /// into BrowserHistoryStore.
    ///
    /// Reads the target profile from `UserDefaults` (key: `ChromeCookieSettings.profileKey`),
    /// falling back to `"Default"`. Runs on a background queue; completion is called on main thread.
    static func importCookies(
        profile: String? = nil,
        completion: @escaping (ImportResult) -> Void
    ) {
        let targetProfile = profile
            ?? UserDefaults.standard.string(forKey: ChromeCookieSettings.profileKey)
            ?? ChromeCookieSettings.defaultProfile

        shared.importQueue.async {
            do {
                guard isChromeInstalled else {
                    throw ImportError.chromeNotInstalled
                }

                let password = try readChromeKeychainPassword()
                #if DEBUG
                NSLog("[ChromeCookieImporter] keychain access OK, deriving key")
                #endif
                let key = deriveKey(fromPassword: password)
                let cookies = try readCookies(profile: targetProfile, key: key)
                #if DEBUG
                NSLog("[ChromeCookieImporter] read \(cookies.count) cookies from Chrome profile '\(targetProfile)'")
                #endif

                // Import history (best-effort, don't fail the whole import if this errors)
                let historyEntries: [BrowserHistoryStore.Entry] = (try? readHistory(profile: targetProfile)) ?? []
                #if DEBUG
                if !historyEntries.isEmpty {
                    NSLog("[ChromeCookieImporter] read \(historyEntries.count) history entries from Chrome")
                }
                #endif

                Task { @MainActor in
                    applyImportedData(cookies: cookies, historyEntries: historyEntries, completion: completion)
                }

            } catch let error as ImportError {
                DispatchQueue.main.async {
                    completion(ImportResult(cookieCount: 0, error: error))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(ImportResult(cookieCount: 0, error: .decryptionFailed))
                }
            }
        }
    }
}
