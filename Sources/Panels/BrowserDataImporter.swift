import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif

#if canImport(CommonCrypto) && canImport(Security)
private struct ChromiumCookieKeychainItem: Hashable {
    let service: String
    let account: String
}

private final class ChromiumCookieDecryptor {
    private enum KeychainLookupResult {
        case success(Data)
        case failure(OSStatus)
    }

    enum FailureReason {
        case keychain(OSStatus)
        case itemNotFound
        case unreadableSecret
        case decrypt
        case unsupportedFormat
    }

    private let browser: InstalledBrowserCandidate
    private var cachedKeychainItem: ChromiumCookieKeychainItem?
    private var cachedPasswordData: Data?
    private var attemptedLookup = false
    private(set) var lastFailureReason: FailureReason?

    init(browser: InstalledBrowserCandidate) {
        self.browser = browser
    }

    var resolvedKeychainItemName: String? {
        cachedKeychainItem?.service
    }

    func decryptCookieValue(encryptedValue: Data, host: String) -> String? {
        guard let versionPrefix = chromiumVersionPrefix(in: encryptedValue) else {
            lastFailureReason = .unsupportedFormat
            return nil
        }

        guard let passwordData = passwordData() else {
            return nil
        }

        let ciphertext = encryptedValue.dropFirst(versionPrefix.count)
        guard let key = deriveKey(from: passwordData),
              let plaintext = decrypt(ciphertext: Data(ciphertext), key: key),
              let cookieValue = decodePlaintext(plaintext, host: host) else {
            lastFailureReason = .decrypt
            return nil
        }

        lastFailureReason = nil
        return cookieValue
    }

    func warningMessage(browserName: String, skippedCount: Int) -> String? {
        guard skippedCount > 0, let failure = lastFailureReason else { return nil }
        switch failure {
        case .keychain, .itemNotFound, .unreadableSecret:
            let itemName = resolvedKeychainItemName ?? suggestedKeychainItems().first?.service ?? "\(browserName) Storage Key"
            return String(
                format: String(
                    localized: "browser.import.warning.keychainDecryptFailed",
                    defaultValue: "Skipped %ld encrypted %@ cookies because %@ could not be unlocked from Keychain."
                ),
                skippedCount,
                browserName,
                itemName
            )
        case .decrypt, .unsupportedFormat:
            return String(
                format: String(
                    localized: "browser.import.warning.encryptedCookiesSkipped",
                    defaultValue: "Skipped %ld encrypted cookies that require Keychain decryption."
                ),
                skippedCount
            )
        }
    }

    private func passwordData() -> Data? {
        if let cachedPasswordData {
            return cachedPasswordData
        }
        guard !attemptedLookup else {
            return nil
        }
        attemptedLookup = true

        for item in suggestedKeychainItems() {
            switch readPasswordData(item: item) {
            case .success(let passwordData):
                guard !passwordData.isEmpty else {
                    cachedKeychainItem = item
                    lastFailureReason = .unreadableSecret
                    return nil
                }
                cachedKeychainItem = item
                cachedPasswordData = passwordData
                lastFailureReason = nil
                return passwordData
            case .failure(let status):
                if status == errSecItemNotFound {
                    continue
                }
                cachedKeychainItem = item
                lastFailureReason = .keychain(status)
                return nil
            }
        }

        lastFailureReason = .itemNotFound
        return nil
    }

    private func suggestedKeychainItems() -> [ChromiumCookieKeychainItem] {
        var result: [ChromiumCookieKeychainItem] = []
        var seen = Set<ChromiumCookieKeychainItem>()

        func append(service: String, account: String) {
            let trimmedService = service.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedService.isEmpty, !trimmedAccount.isEmpty else { return }
            let item = ChromiumCookieKeychainItem(service: trimmedService, account: trimmedAccount)
            if seen.insert(item).inserted {
                result.append(item)
            }
        }

        for baseName in keychainBaseNames() {
            append(service: "\(baseName) Storage Key", account: baseName)
            append(service: "\(baseName) Safe Storage", account: baseName)
        }

        for baseName in keychainBaseNames() {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: baseName,
                kSecReturnAttributes: true,
                kSecMatchLimit: kSecMatchLimitAll,
            ]
            var rawResult: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &rawResult)
            guard status == errSecSuccess else { continue }
            let attributesList = rawResult as? [[String: Any]] ?? []
            for attributes in attributesList {
                guard let service = attributes[kSecAttrService as String] as? String else { continue }
                guard service.contains("Storage Key") || service.contains("Safe Storage") else { continue }
                append(service: service, account: baseName)
            }
        }

        return result
    }

    private func keychainBaseNames() -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ rawName: String?) {
            guard let rawName else { return }
            let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return }
            if seen.insert(trimmedName).inserted {
                result.append(trimmedName)
            }
        }

        append(browser.displayName)
        append(browser.appURL?.deletingPathExtension().lastPathComponent)
        append(browser.descriptor.appNames.first?.replacingOccurrences(of: ".app", with: ""))

        if let appURL = browser.appURL,
           let bundle = Bundle(url: appURL) {
            append(bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            append(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        }

        for name in Array(result) {
            if name.hasPrefix("Google ") {
                append(String(name.dropFirst("Google ".count)))
            }
            if name.hasSuffix(" Browser") {
                append(String(name.dropLast(" Browser".count)))
            }
        }

        switch browser.descriptor.id {
        case "google-chrome":
            append("Chrome")
        case "chromium":
            append("Chromium")
        case "brave":
            append("Brave")
        case "helium":
            append("Helium")
        default:
            break
        }

        return result
    }

    private func readPasswordData(item: ChromiumCookieKeychainItem) -> KeychainLookupResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: item.service,
            kSecAttrAccount: item.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var rawResult: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &rawResult)
        guard status == errSecSuccess else {
            return .failure(status)
        }
        guard let passwordData = rawResult as? Data else {
            return .failure(errSecDecode)
        }
        return .success(passwordData)
    }

    private func chromiumVersionPrefix(in encryptedValue: Data) -> Data? {
        for prefix in [Data("v10".utf8), Data("v11".utf8)] where encryptedValue.starts(with: prefix) {
            return prefix
        }
        return nil
    }

    private func deriveKey(from passwordData: Data) -> Data? {
        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(count: kCCKeySizeAES128)

        let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        kCCKeySizeAES128
                    )
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return derivedKey
    }

    private func decrypt(ciphertext: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var plaintextLength = 0
        let plaintextCapacity = plaintext.count

        let status = plaintext.withUnsafeMutableBytes { plaintextBytes in
            ciphertext.withUnsafeBytes { ciphertextBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            ciphertextBytes.baseAddress,
                            ciphertext.count,
                            plaintextBytes.baseAddress,
                            plaintextCapacity,
                            &plaintextLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        plaintext.removeSubrange(plaintextLength...)
        return plaintext
    }

    private func decodePlaintext(_ plaintext: Data, host: String) -> String? {
        if let value = String(data: plaintext, encoding: .utf8) {
            return value
        }

        let hostDigest = Data(SHA256.hash(data: Data(host.utf8)))
        if plaintext.starts(with: hostDigest) {
            return String(data: plaintext.dropFirst(hostDigest.count), encoding: .utf8)
        }

        return nil
    }
}
#else
private final class ChromiumCookieDecryptor {
    init(browser: InstalledBrowserCandidate) {}

    func decryptCookieValue(encryptedValue: Data, host: String) -> String? { nil }

    func warningMessage(browserName: String, skippedCount: Int) -> String? {
        guard skippedCount > 0 else { return nil }
        return String(
            format: String(
                localized: "browser.import.warning.encryptedCookiesSkipped",
                defaultValue: "Skipped %ld encrypted cookies that require Keychain decryption."
            ),
            skippedCount
        )
    }
}
#endif

enum BrowserDataImporter {
    private struct CookieImportResult {
        var importedCount: Int = 0
        var skippedCount: Int = 0
        var warnings: [String] = []
    }

    private struct HistoryImportResult {
        var importedCount: Int = 0
        var warnings: [String] = []
    }

    private struct HistoryRow {
        let url: String
        let title: String?
        let visitCount: Int
        let lastVisited: Date
    }

    static func parseDomainFilters(_ raw: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        for token in raw.components(separatedBy: separators) {
            var value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.hasPrefix("*.") {
                value.removeFirst(2)
            }
            while value.hasPrefix(".") {
                value.removeFirst()
            }
            guard !value.isEmpty else { continue }
            guard seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    static func importData(
        from browser: InstalledBrowserCandidate,
        plan: RealizedBrowserImportExecutionPlan,
        scope: BrowserImportScope,
        domainFilters: [String]
    ) async -> BrowserImportOutcome {
        var outcomeEntries: [BrowserImportOutcomeEntry] = []
        var warnings: [String] = []
        var seenWarnings = Set<String>()

        for entry in plan.entries {
            let outcomeEntry = await importEntry(
                from: browser,
                sourceProfiles: entry.sourceProfiles,
                destinationProfileID: entry.destinationProfileID,
                destinationProfileName: entry.destinationProfileName,
                scope: scope,
                domainFilters: domainFilters
            )
            outcomeEntries.append(outcomeEntry)
            for warning in outcomeEntry.warnings where seenWarnings.insert(warning).inserted {
                warnings.append(warning)
            }
        }

        if scope == .everything {
            let unavailableWarning = String(
                localized: "browser.import.warning.additionalDataUnavailable",
                defaultValue: "Bookmarks, settings, and extensions import are not available yet. Imported cookies and history only."
            )
            if seenWarnings.insert(unavailableWarning).inserted {
                warnings.append(unavailableWarning)
            }
        }

        return BrowserImportOutcome(
            browserName: browser.displayName,
            scope: scope,
            domainFilters: domainFilters,
            createdDestinationProfileNames: plan.createdProfiles.map(\.displayName),
            entries: outcomeEntries,
            warnings: warnings
        )
    }

    private static func importEntry(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        destinationProfileName: String,
        scope: BrowserImportScope,
        domainFilters: [String]
    ) async -> BrowserImportOutcomeEntry {
        let resolvedSourceProfiles = sourceProfiles.isEmpty ? browser.profiles : sourceProfiles
        var cookieResult = CookieImportResult()
        if scope.includesCookies {
            cookieResult = await importCookies(
                from: browser,
                sourceProfiles: resolvedSourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        }

        var historyResult = HistoryImportResult()
        if scope.includesHistory {
            historyResult = await importHistory(
                from: browser,
                sourceProfiles: resolvedSourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        }

        var warnings = cookieResult.warnings
        warnings.append(contentsOf: historyResult.warnings)
        return BrowserImportOutcomeEntry(
            sourceProfileNames: resolvedSourceProfiles.map(\.displayName),
            destinationProfileName: destinationProfileName,
            importedCookies: cookieResult.importedCount,
            skippedCookies: cookieResult.skippedCount,
            importedHistoryEntries: historyResult.importedCount,
            warnings: warnings
        )
    }

    private static func importCookies(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> CookieImportResult {
        switch browser.family {
        case .firefox:
            return await importFirefoxCookies(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .chromium:
            return await importChromiumCookies(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .webkit:
            if browser.descriptor.id == "safari" {
                return CookieImportResult(
                    importedCount: 0,
                    skippedCount: 0,
                    warnings: [
                        String(
                            localized: "browser.import.warning.safariCookiesUnsupported",
                            defaultValue: "Safari cookies are stored in Cookies.binarycookies and are not yet supported by this importer."
                        )
                    ]
                )
            }
            return CookieImportResult(
                importedCount: 0,
                skippedCount: 0,
                warnings: [
                    String(
                        format: String(
                            localized: "browser.import.warning.cookieImportUnsupported",
                            defaultValue: "%@ cookie import is not implemented yet."
                        ),
                        browser.displayName
                    )
                ]
            )
        }
    }

    private static func importHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        switch browser.family {
        case .firefox:
            return await importFirefoxHistory(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .chromium:
            return await importChromiumHistory(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        case .webkit:
            return await importWebKitHistory(
                from: browser,
                sourceProfiles: sourceProfiles,
                destinationProfileID: destinationProfileID,
                domainFilters: domainFilters
            )
        }
    }

    private static func importFirefoxCookies(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> CookieImportResult {
        let fileManager = FileManager.default
        var cookies: [HTTPCookie] = []
        var warnings: [String] = []

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("cookies.sqlite", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: "SELECT host, name, value, path, expiry, isSecure FROM moz_cookies"
                ) { statement in
                    let host = sqliteColumnText(statement, index: 0) ?? ""
                    let name = sqliteColumnText(statement, index: 1) ?? ""
                    let value = sqliteColumnText(statement, index: 2) ?? ""
                    let path = sqliteColumnText(statement, index: 3) ?? "/"
                    let expiry = sqliteColumnInt64(statement, index: 4)
                    let isSecure = sqliteColumnInt64(statement, index: 5) != 0

                    guard !name.isEmpty else { return }
                    guard domainMatches(host: host, filters: domainFilters) else { return }

                    var properties: [HTTPCookiePropertyKey: Any] = [
                        .domain: host,
                        .path: path.isEmpty ? "/" : path,
                        .name: name,
                        .value: value,
                    ]
                    if isSecure {
                        properties[.secure] = "TRUE"
                    }
                    if expiry > 0 {
                        properties[.expires] = Date(timeIntervalSince1970: TimeInterval(expiry))
                    }
                    if let cookie = HTTPCookie(properties: properties) {
                        cookies.append(cookie)
                    }
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.firefoxCookiesReadFailed",
                            defaultValue: "Failed reading Firefox cookies at %@: %@"
                        ),
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let dedupedCookies = dedupeCookies(cookies)
        let importedCount = await setCookiesInStore(dedupedCookies, destinationProfileID: destinationProfileID)
        return CookieImportResult(importedCount: importedCount, skippedCount: max(0, dedupedCookies.count - importedCount), warnings: warnings)
    }

    private static func importChromiumCookies(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> CookieImportResult {
        let fileManager = FileManager.default
        var cookies: [HTTPCookie] = []
        var warnings: [String] = []
        var skippedEncryptedCookies = 0
        let decryptor = ChromiumCookieDecryptor(browser: browser)

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("Cookies", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: "SELECT host_key, name, value, path, expires_utc, is_secure, encrypted_value FROM cookies"
                ) { statement in
                    let host = sqliteColumnText(statement, index: 0) ?? ""
                    let name = sqliteColumnText(statement, index: 1) ?? ""
                    let value = sqliteColumnText(statement, index: 2) ?? ""
                    let path = sqliteColumnText(statement, index: 3) ?? "/"
                    let expiresUTC = sqliteColumnInt64(statement, index: 4)
                    let isSecure = sqliteColumnInt64(statement, index: 5) != 0
                    let encryptedValue = sqliteColumnData(statement, index: 6)

                    guard !name.isEmpty else { return }
                    guard domainMatches(host: host, filters: domainFilters) else { return }

                    var usableValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if usableValue.isEmpty && !encryptedValue.isEmpty {
                        if let decryptedValue = decryptor.decryptCookieValue(
                            encryptedValue: encryptedValue,
                            host: host
                        ) {
                            usableValue = decryptedValue
                        } else {
                            skippedEncryptedCookies += 1
                            return
                        }
                    }

                    var properties: [HTTPCookiePropertyKey: Any] = [
                        .domain: host,
                        .path: path.isEmpty ? "/" : path,
                        .name: name,
                        .value: usableValue,
                    ]
                    if isSecure {
                        properties[.secure] = "TRUE"
                    }
                    if let expiresDate = chromiumDate(fromWebKitMicroseconds: expiresUTC) {
                        properties[.expires] = expiresDate
                    }
                    if let cookie = HTTPCookie(properties: properties) {
                        cookies.append(cookie)
                    }
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.browserCookiesReadFailed",
                            defaultValue: "Failed reading %@ cookies at %@: %@"
                        ),
                        browser.displayName,
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let dedupedCookies = dedupeCookies(cookies)
        let importedCount = await setCookiesInStore(dedupedCookies, destinationProfileID: destinationProfileID)
        if let warning = decryptor.warningMessage(
            browserName: browser.displayName,
            skippedCount: skippedEncryptedCookies
        ) {
            warnings.append(warning)
        }
        let skippedCount = max(0, dedupedCookies.count - importedCount) + skippedEncryptedCookies
        return CookieImportResult(importedCount: importedCount, skippedCount: skippedCount, warnings: warnings)
    }

    private static func importFirefoxHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("places.sqlite", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: """
                    SELECT url, title, visit_count, last_visit_date
                    FROM moz_places
                    WHERE url LIKE 'http%'
                    ORDER BY last_visit_date DESC
                    LIMIT 5000
                    """
                ) { statement in
                    let url = sqliteColumnText(statement, index: 0) ?? ""
                    let title = sqliteColumnText(statement, index: 1)
                    let visitCount = max(1, Int(sqliteColumnInt64(statement, index: 2)))
                    let lastVisitMicros = sqliteColumnInt64(statement, index: 3)
                    guard let parsedURL = URL(string: url),
                          let host = parsedURL.host,
                          domainMatches(host: host, filters: domainFilters) else {
                        return
                    }
                    let lastVisited = firefoxDate(fromUnixMicroseconds: lastVisitMicros) ?? .distantPast
                    rows.append(HistoryRow(url: url, title: title, visitCount: visitCount, lastVisited: lastVisited))
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.firefoxHistoryReadFailed",
                            defaultValue: "Failed reading Firefox history at %@: %@"
                        ),
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let importedCount = await mergeHistoryRows(rows, destinationProfileID: destinationProfileID)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func importChromiumHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        let databaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("History", isDirectory: false)
        }.filter { fileManager.fileExists(atPath: $0.path) }

        for databaseURL in databaseURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: """
                    SELECT url, title, visit_count, last_visit_time
                    FROM urls
                    WHERE url LIKE 'http%'
                    ORDER BY last_visit_time DESC
                    LIMIT 5000
                    """
                ) { statement in
                    let url = sqliteColumnText(statement, index: 0) ?? ""
                    let title = sqliteColumnText(statement, index: 1)
                    let visitCount = max(1, Int(sqliteColumnInt64(statement, index: 2)))
                    let lastVisitMicros = sqliteColumnInt64(statement, index: 3)
                    guard let parsedURL = URL(string: url),
                          let host = parsedURL.host,
                          domainMatches(host: host, filters: domainFilters) else {
                        return
                    }
                    let lastVisited = chromiumDate(fromWebKitMicroseconds: lastVisitMicros) ?? .distantPast
                    rows.append(HistoryRow(url: url, title: title, visitCount: visitCount, lastVisited: lastVisited))
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.browserHistoryReadFailed",
                            defaultValue: "Failed reading %@ history at %@: %@"
                        ),
                        browser.displayName,
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let importedCount = await mergeHistoryRows(rows, destinationProfileID: destinationProfileID)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func importWebKitHistory(
        from browser: InstalledBrowserCandidate,
        sourceProfiles: [InstalledBrowserProfile],
        destinationProfileID: UUID,
        domainFilters: [String]
    ) async -> HistoryImportResult {
        let fileManager = FileManager.default
        var rows: [HistoryRow] = []
        var warnings: [String] = []

        var candidateDatabaseURLs = sourceProfiles.map {
            $0.rootURL.appendingPathComponent("History.db", isDirectory: false)
        }
        if browser.descriptor.id == "safari" {
            candidateDatabaseURLs.append(
                browser.homeDirectoryURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Safari", isDirectory: true)
                    .appendingPathComponent("History.db", isDirectory: false)
            )
        }
        let uniqueURLs = dedupedCanonicalURLs(candidateDatabaseURLs).filter { fileManager.fileExists(atPath: $0.path) }

        if uniqueURLs.isEmpty {
            return HistoryImportResult(
                importedCount: 0,
                warnings: [
                    String(
                        format: String(
                            localized: "browser.import.warning.noHistoryDatabase",
                            defaultValue: "No history database found for %@."
                        ),
                        browser.displayName
                    )
                ]
            )
        }

        for databaseURL in uniqueURLs {
            do {
                try querySQLiteRows(
                    sourceDatabaseURL: databaseURL,
                    sql: """
                    SELECT history_items.url,
                           history_items.title,
                           COUNT(history_visits.id) AS visit_count,
                           MAX(history_visits.visit_time) AS last_visit_time
                    FROM history_items
                    JOIN history_visits
                      ON history_items.id = history_visits.history_item
                    GROUP BY history_items.url
                    ORDER BY last_visit_time DESC
                    LIMIT 5000
                    """
                ) { statement in
                    let url = sqliteColumnText(statement, index: 0) ?? ""
                    let title = sqliteColumnText(statement, index: 1)
                    let visitCount = max(1, Int(sqliteColumnInt64(statement, index: 2)))
                    let lastVisitReferenceSeconds = sqliteColumnDouble(statement, index: 3)
                    guard let parsedURL = URL(string: url),
                          let host = parsedURL.host,
                          domainMatches(host: host, filters: domainFilters) else {
                        return
                    }
                    let lastVisited = Date(timeIntervalSinceReferenceDate: lastVisitReferenceSeconds)
                    rows.append(HistoryRow(url: url, title: title, visitCount: visitCount, lastVisited: lastVisited))
                }
            } catch {
                warnings.append(
                    String(
                        format: String(
                            localized: "browser.import.warning.browserHistoryReadFailed",
                            defaultValue: "Failed reading %@ history at %@: %@"
                        ),
                        browser.displayName,
                        databaseURL.lastPathComponent,
                        error.localizedDescription
                    )
                )
            }
        }

        let importedCount = await mergeHistoryRows(rows, destinationProfileID: destinationProfileID)
        return HistoryImportResult(importedCount: importedCount, warnings: warnings)
    }

    private static func mergeHistoryRows(_ rows: [HistoryRow], destinationProfileID: UUID) async -> Int {
        guard !rows.isEmpty else { return 0 }
        return await MainActor.run {
            let entries = rows.compactMap { row -> BrowserHistoryStore.Entry? in
                guard let parsedURL = URL(string: row.url),
                      let scheme = parsedURL.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    return nil
                }
                let trimmedTitle = row.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return BrowserHistoryStore.Entry(
                    id: UUID(),
                    url: parsedURL.absoluteString,
                    title: trimmedTitle,
                    lastVisited: row.lastVisited,
                    visitCount: max(1, row.visitCount)
                )
            }
            let historyStore = BrowserProfileStore.shared.historyStore(for: destinationProfileID)
            return historyStore.mergeImportedEntries(entries)
        }
    }

    private static func setCookiesInStore(_ cookies: [HTTPCookie], destinationProfileID: UUID) async -> Int {
        guard !cookies.isEmpty else { return 0 }
        let store = await MainActor.run {
            BrowserProfileStore.shared.websiteDataStore(for: destinationProfileID).httpCookieStore
        }
        var importedCount = 0
        for (index, cookie) in cookies.enumerated() {
            if await setCookie(cookie, in: store) {
                importedCount += 1
            }
            if index > 0 && index.isMultiple(of: 50) {
                await Task.yield()
            }
        }
        return importedCount
    }

    @MainActor
    private static func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async -> Bool {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) {
                continuation.resume(returning: true)
            }
        }
    }

    private static func dedupeCookies(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        var dedupedByKey: [String: HTTPCookie] = [:]
        for cookie in cookies {
            let key = "\(cookie.name.lowercased())|\(cookie.domain.lowercased())|\(cookie.path)"
            if let existing = dedupedByKey[key] {
                let existingExpiry = existing.expiresDate ?? .distantPast
                let candidateExpiry = cookie.expiresDate ?? .distantPast
                if candidateExpiry >= existingExpiry {
                    dedupedByKey[key] = cookie
                }
            } else {
                dedupedByKey[key] = cookie
            }
        }
        return Array(dedupedByKey.values)
    }

    private static func domainMatches(host: String, filters: [String]) -> Bool {
        if filters.isEmpty { return true }
        var normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalizedHost.hasPrefix(".") {
            normalizedHost.removeFirst()
        }
        guard !normalizedHost.isEmpty else { return false }
        for filter in filters {
            if normalizedHost == filter { return true }
            if normalizedHost.hasSuffix(".\(filter)") { return true }
        }
        return false
    }

    private static func chromiumDate(fromWebKitMicroseconds rawValue: Int64) -> Date? {
        guard rawValue > 0 else { return nil }
        let unixSeconds = (Double(rawValue) / 1_000_000.0) - 11_644_473_600.0
        guard unixSeconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: unixSeconds)
    }

    private static func firefoxDate(fromUnixMicroseconds rawValue: Int64) -> Date? {
        guard rawValue > 0 else { return nil }
        let seconds = Double(rawValue) / 1_000_000.0
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func querySQLiteRows(
        sourceDatabaseURL: URL,
        sql: String,
        rowHandler: (OpaquePointer) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-browser-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let snapshotURL = tempRoot.appendingPathComponent(sourceDatabaseURL.lastPathComponent, isDirectory: false)
        try fileManager.copyItem(at: sourceDatabaseURL, to: snapshotURL)

        let walSourceURL = URL(fileURLWithPath: "\(sourceDatabaseURL.path)-wal")
        let walSnapshotURL = URL(fileURLWithPath: "\(snapshotURL.path)-wal")
        if fileManager.fileExists(atPath: walSourceURL.path) {
            try? fileManager.copyItem(at: walSourceURL, to: walSnapshotURL)
        }
        let shmSourceURL = URL(fileURLWithPath: "\(sourceDatabaseURL.path)-shm")
        let shmSnapshotURL = URL(fileURLWithPath: "\(snapshotURL.path)-shm")
        if fileManager.fileExists(atPath: shmSourceURL.path) {
            try? fileManager.copyItem(at: shmSourceURL, to: shmSnapshotURL)
        }

        var database: OpaquePointer?
        let openCode = sqlite3_open_v2(snapshotURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let database else {
            let message = sqliteMessage(from: database) ?? "unknown SQLite open failure"
            sqlite3_close(database)
            throw NSError(domain: "BrowserDataImporter", code: Int(openCode), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            let message = sqliteMessage(from: database) ?? "unknown SQLite prepare failure"
            sqlite3_finalize(statement)
            throw NSError(domain: "BrowserDataImporter", code: Int(prepareCode), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        defer { sqlite3_finalize(statement) }

        while true {
            let stepCode = sqlite3_step(statement)
            if stepCode == SQLITE_ROW {
                try rowHandler(statement)
                continue
            }
            if stepCode == SQLITE_DONE {
                break
            }
            let message = sqliteMessage(from: database) ?? "unknown SQLite step failure"
            throw NSError(domain: "BrowserDataImporter", code: Int(stepCode), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    private static func sqliteMessage(from database: OpaquePointer?) -> String? {
        guard let database, let cString = sqlite3_errmsg(database) else { return nil }
        return String(cString: cString)
    }

    private static func sqliteColumnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cValue = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cValue)
    }

    private static func sqliteColumnInt64(_ statement: OpaquePointer, index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    private static func sqliteColumnDouble(_ statement: OpaquePointer, index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    private static func sqliteColumnBytes(_ statement: OpaquePointer, index: Int32) -> Int {
        Int(sqlite3_column_bytes(statement, index))
    }

    private static func sqliteColumnData(_ statement: OpaquePointer, index: Int32) -> Data {
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length > 0, let pointer = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: pointer, count: length)
    }
}

#if DEBUG
enum BrowserImportUITestFixtureLoader {
    private struct BrowserFixture: Decodable {
        let browserName: String
        let profiles: [String]
    }

    static func browsers(from environment: [String: String]) -> [InstalledBrowserCandidate]? {
        guard let rawFixture = environment["CMUX_UI_TEST_BROWSER_IMPORT_FIXTURE"],
              let data = rawFixture.data(using: .utf8),
              let fixture = try? JSONDecoder().decode(BrowserFixture.self, from: data) else {
            return nil
        }

        let resolvedProfiles = fixture.profiles.enumerated().map { index, name in
            InstalledBrowserProfile(
                displayName: name,
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-ui-test-browser-import")
                    .appendingPathComponent(
                        fixture.browserName
                            .lowercased()
                            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                    )
                    .appendingPathComponent("\(index)-\(name)")
                    .standardizedFileURL,
                isDefault: index == 0
            )
        }

        let descriptor = InstalledBrowserDetector.allBrowserDescriptors.first(where: {
            $0.displayName == fixture.browserName
        }) ?? BrowserImportBrowserDescriptor(
            id: fixture.browserName
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-")),
            displayName: fixture.browserName,
            family: .chromium,
            tier: 0,
            bundleIdentifiers: [],
            appNames: [],
            dataRootRelativePaths: [],
            dataArtifactRelativePaths: [],
            supportsDataOnlyDetection: false
        )

        return [
            InstalledBrowserCandidate(
                descriptor: descriptor,
                resolvedFamily: descriptor.family,
                homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
                appURL: nil,
                dataRootURL: nil,
                profiles: resolvedProfiles,
                detectionSignals: ["ui-test-fixture"],
                detectionScore: Int.max
            )
        ]
    }

    static func destinationProfiles(from environment: [String: String]) -> [BrowserProfileDefinition]? {
        guard let rawDestinations = environment["CMUX_UI_TEST_BROWSER_IMPORT_DESTINATIONS"],
              let data = rawDestinations.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data),
              !names.isEmpty else {
            return nil
        }

        return names.enumerated().map { index, rawName in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.localizedCaseInsensitiveCompare("Default") == .orderedSame {
                return BrowserProfileDefinition(
                    id: UUID(uuidString: "52B43C05-4A1D-45D3-8FD5-9EF94952E445")!,
                    displayName: "Default",
                    createdAt: .distantPast,
                    isBuiltInDefault: true
                )
            }
            return BrowserProfileDefinition(
                id: UUID(),
                displayName: name.isEmpty ? "Profile \(index + 1)" : name,
                createdAt: .distantPast,
                isBuiltInDefault: false
            )
        }
    }
}
#endif
