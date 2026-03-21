import Foundation
import Security
import CommonCrypto
import SQLite3
import WebKit

// MARK: - Settings constants (temporary; will move to BrowserPanel.swift in Task 2)

enum ChromeCookieSettings {
    static let autoImportEnabledKey = "browserChromeCookieAutoImport"
    static let profileKey = "browserChromeCookieProfile"
    static let defaultAutoImportEnabled = false
    static let defaultProfile = "Default"
}

// MARK: - ChromeCookieImporter

final class ChromeCookieImporter {

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
                return "Google Chrome is not installed or its data directory is missing."
            case .keychainAccessDenied:
                return "Access to the Chrome Safe Storage keychain item was denied."
            case .keychainError(let status):
                return "Keychain error: \(status)"
            case .databaseOpenFailed(let reason):
                return "Failed to open Chrome cookie database: \(reason)"
            case .decryptionFailed:
                return "Failed to decrypt Chrome cookie values."
            case .noProfile(let name):
                return "Chrome profile not found: \(name)"
            }
        }
    }

    // MARK: - Import result

    struct ImportResult {
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

    /// Microseconds between 1601-01-01 and 1970-01-01 (Unix epoch).
    private static let chromeEpochOffset: Int64 = 11_644_473_600

    private init() {}

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
            if lhs.directory == "Default" { return true }
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
    func cookieDBPath(profile: String) -> String {
        "\(Self.chromeAppSupportPath)/\(profile)/Cookies"
    }

    // MARK: - Step 2: Keychain access

    /// Reads the "Chrome Safe Storage" password from macOS Keychain.
    func readChromeKeychainPassword() throws -> String {
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
    func deriveKey(fromPassword password: String) -> [UInt8] {
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
    func decryptCookieValue(_ encryptedData: Data, key: [UInt8]) -> String? {
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

        return String(bytes: decryptedBytes.prefix(decryptedLength), encoding: .utf8)
    }

    // MARK: - Step 4: SQLite reading

    /// Reads and decrypts cookies from Chrome's SQLite database.
    func readCookies(profile: String, key: [UInt8]) throws -> [HTTPCookie] {
        let dbPath = cookieDBPath(profile: profile)
        let fm = FileManager.default

        guard fm.fileExists(atPath: dbPath) else {
            throw ImportError.noProfile(profile)
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let openStatus = sqlite3_open_v2(dbPath, &db, flags, nil)

        guard openStatus == SQLITE_OK, let db = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw ImportError.databaseOpenFailed(message)
        }

        defer { sqlite3_close(db) }

        var cookies: [HTTPCookie] = []

        let query = """
            SELECT host_key, name, path, encrypted_value, is_secure, is_httponly, expires_utc
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

            // Decrypt cookie value
            let blobPtr = sqlite3_column_blob(stmt, 3)
            let blobLen = sqlite3_column_bytes(stmt, 3)

            var value = ""
            if let blobPtr = blobPtr, blobLen > 0 {
                let encryptedData = Data(bytes: blobPtr, count: Int(blobLen))
                if let decrypted = decryptCookieValue(encryptedData, key: key) {
                    value = decrypted
                } else {
                    // Skip cookies we cannot decrypt
                    continue
                }
            }

            let isSecure = sqlite3_column_int(stmt, 4) != 0
            let isHttpOnly = sqlite3_column_int(stmt, 5) != 0

            // Build domain: prefix with "." if not already prefixed
            let domain = hostKey.hasPrefix(".") ? hostKey : ".\(hostKey)"

            // Convert Chrome timestamp to Unix Date
            let expiresDate: Date?
            if expiresUtc > 0 {
                let unixSeconds = TimeInterval(expiresUtc / 1_000_000) - TimeInterval(Self.chromeEpochOffset)
                expiresDate = Date(timeIntervalSince1970: unixSeconds)
            } else {
                expiresDate = nil
            }

            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: path,
                .name: name,
                .value: value,
                .secure: isSecure ? "TRUE" : "FALSE",
            ]

            if isHttpOnly {
                // NSHTTPCookieHTTPOnly is not exposed as a public property key constant,
                // but it is recognized when constructing HTTPCookie.
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
    private func currentChromeTimestamp() -> Int64 {
        let unixSeconds = Int64(Date().timeIntervalSince1970)
        return (unixSeconds + Self.chromeEpochOffset) * 1_000_000
    }

    // MARK: - Step 5: Public import API

    /// Imports Chrome cookies into WKWebView's default cookie store.
    ///
    /// Reads the target profile from `UserDefaults` (key: `ChromeCookieSettings.profileKey`),
    /// falling back to `"Default"`. Runs on a background queue; completion is called on main thread.
    static func importCookies(
        profile: String? = nil,
        completion: @escaping (ImportResult) -> Void
    ) {
        let importer = shared
        let targetProfile = profile
            ?? UserDefaults.standard.string(forKey: ChromeCookieSettings.profileKey)
            ?? ChromeCookieSettings.defaultProfile

        importer.importQueue.async {
            do {
                guard isChromeInstalled else {
                    throw ImportError.chromeNotInstalled
                }

                let password = try importer.readChromeKeychainPassword()
                let key = importer.deriveKey(fromPassword: password)
                let cookies = try importer.readCookies(profile: targetProfile, key: key)

                guard !cookies.isEmpty else {
                    DispatchQueue.main.async {
                        completion(ImportResult(cookieCount: 0, error: nil))
                    }
                    return
                }

                let cookieStore = WKWebsiteDataStore.default().httpCookieStore
                let group = DispatchGroup()

                for cookie in cookies {
                    group.enter()
                    DispatchQueue.main.async {
                        cookieStore.setCookie(cookie) {
                            group.leave()
                        }
                    }
                }

                group.notify(queue: .main) {
                    completion(ImportResult(cookieCount: cookies.count, error: nil))
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
