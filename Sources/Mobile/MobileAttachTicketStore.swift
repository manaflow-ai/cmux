import CMUXMobileCore
import CmuxSettings
import CryptoKit
import Foundation
#if canImport(Security)
import Security
#endif

enum MobileAttachTicketStoreError: Error {
    case noRoutes
    case routeUnavailable
    case invalidAttachURL
}

final class MobileAttachTicketStore {
    private struct Record: Codable {
        let ticket: CmxAttachTicket
        let issuedAt: Date
        var createdWorkspaceIDs: Set<String> = []
        var createdTerminalIDs: Set<String> = []
    }

    private let lock = NSLock()
    private var recordsByAuthToken: [String: Record] = [:]
    private var persistentAuthTokens: Set<String>
    private var lastPersistentPruneAt: Date?
    private static let persistentPruneInterval: TimeInterval = 5 * 60
    private static let maxPersistentRecordCount = 512

    init() {
        persistentAuthTokens = MobileAttachTicketStore.loadPersistentAuthTokenIndex()
    }

    func createTicket(
        workspaceID: String,
        terminalID: String?,
        routes: [CmxAttachRoute],
        ttl: TimeInterval,
        macUserEmail: String? = nil,
        macUserID: String? = nil,
        macPairingCompatibilityVersion: Int? = nil,
        macAppVersion: String? = nil,
        macAppBuild: String? = nil,
        now: Date = Date()
    ) throws -> CmxAttachTicket {
        lock.lock()
        defer { lock.unlock() }

        pruneExpiredLoadedRecords(now: now)
        pruneExpiredPersistentRecordsIfDue(now: now)
        guard !routes.isEmpty else {
            throw MobileAttachTicketStoreError.noRoutes
        }

        let ticket = try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: MobileHostIdentity.deviceID(),
            macDisplayName: MobileHostIdentity.displayName(),
            macUserEmail: macUserEmail,
            macUserID: macUserID,
            macPairingCompatibilityVersion: macPairingCompatibilityVersion,
            macAppVersion: macAppVersion,
            macAppBuild: macAppBuild,
            routes: routes,
            expiresAt: now.addingTimeInterval(max(30, ttl)),
            authToken: Self.randomBearerToken()
        )
        if let authToken = ticket.authToken {
            let record = Record(ticket: ticket, issuedAt: now)
            evictOldestPersistentRecordsIfNeeded(reservingSlots: 1)
            recordsByAuthToken[authToken] = record
            persistentAuthTokens.insert(authToken)
            Self.storeRecord(record, authToken: authToken)
            Self.storePersistentAuthTokenIndex(persistentAuthTokens)
        }
        return ticket
    }

    func payload(for ticket: CmxAttachTicket) throws -> [String: Any] {
        var payload: [String: Any] = [
            "ticket": try Self.jsonObject(ticket),
            "attach_url": try attachURL(for: ticket).absoluteString,
            "routes": ticket.routes.map(\.mobileHostJSONObject)
        ]
        // `expires_at` describes the minted attach token's lifetime (tickets
        // from `createTicket` always carry one). The QR payload itself encodes
        // no expiry; a displayed pairing code never goes stale.
        if let expiresAt = ticket.expiresAt {
            payload["expires_at"] = ISO8601DateFormatter().string(from: expiresAt)
        }
        return payload
    }

    func validTicket(authToken: String?, now: Date = Date()) -> CmxAttachTicket? {
        validAuthorization(authToken: authToken, now: now)?.ticket
    }

    func validAuthorization(authToken: String?, now: Date = Date()) -> MobileAttachTicketAuthorization? {
        lock.lock()
        defer { lock.unlock() }

        pruneExpiredLoadedRecords(now: now)
        guard let authToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authToken.isEmpty else {
            return nil
        }
        let record: Record?
        if let cachedRecord = recordsByAuthToken[authToken] {
            record = cachedRecord
        } else if persistentAuthTokens.contains(authToken) {
            record = Self.loadRecord(authToken: authToken)
        } else {
            record = nil
        }
        guard let record else {
            return nil
        }
        if record.ticket.isExpired(at: now) {
            recordsByAuthToken[authToken] = nil
            persistentAuthTokens.remove(authToken)
            Self.deleteRecord(authToken: authToken)
            Self.storePersistentAuthTokenIndex(persistentAuthTokens)
            return nil
        }
        recordsByAuthToken[authToken] = record
        return MobileAttachTicketAuthorization(
            ticket: record.ticket,
            createdWorkspaceIDs: record.createdWorkspaceIDs,
            createdTerminalIDs: record.createdTerminalIDs
        )
    }

    func removeAllRecords() {
        lock.lock()
        defer { lock.unlock() }

        for authToken in persistentAuthTokens {
            Self.deleteRecord(authToken: authToken)
        }
        recordsByAuthToken.removeAll()
        persistentAuthTokens.removeAll()
        Self.storePersistentAuthTokenIndex(persistentAuthTokens)
    }

    func recordCreatedResources(
        authToken: String?,
        workspaceID: String?,
        terminalID: String?,
        now: Date = Date()
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard let authToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authToken.isEmpty,
              var record = recordsByAuthToken[authToken],
              !record.ticket.isExpired(at: now) else {
            return
        }

        if let workspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspaceID.isEmpty {
            record.createdWorkspaceIDs.insert(workspaceID)
        }
        if let terminalID = terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            record.createdTerminalIDs.insert(terminalID)
        }
        recordsByAuthToken[authToken] = record
        Self.storeRecord(record, authToken: authToken)
    }

    private func attachURL(for ticket: CmxAttachTicket) throws -> URL {
        // Preferred form: the minimal v2 pairing-code grammar — bare Tailscale
        // `host:port` routes in the URL query, nothing else. Everything the
        // older grammars carried has a better channel: the auth token is a
        // short-lived credential and stays out of the minimal QR, the display
        // name and device id arrive post-handshake from
        // `mobile.host.status`, and a pairing QR never expires. A DEBUG Mac's
        // dev loopback route is dropped outright (a scanned code must never
        // point a phone at itself). The much shorter plain-text URL also
        // drops the QR several versions, so the code scans faster.
        if let pairingURL = CmxPairingQRCode().encode(ticket), let url = URL(string: pairingURL) {
            return url
        }
        // Fallback for tickets the minimal grammar cannot express (workspace-
        // scoped, custom routes, loopback-only dev tickets): the compact
        // short-key v1 payload. The full ticket (including the token) still
        // rides in `payload(for:)["ticket"]` for RPC consumers.
        let data = try CmxAttachTicketCompactCoder().encode(ticket)
        let payload = Self.base64URLEncode(data)
        // Channel-specific scheme (see ``CmxPairingURLScheme``): the v1 fallback
        // QR must open the matching iOS channel just like the v2 path in
        // ``CmxPairingQRCode/encode(_:)``, so a dev Mac never hands a release
        // phone a code the system camera routes to a dev build (or vice versa).
        guard let url = URL(string: "\(CmxPairingURLScheme.current)://attach?v=\(ticket.version)&payload=\(payload)") else {
            throw MobileAttachTicketStoreError.invalidAttachURL
        }
        return url
    }

    private func pruneExpiredLoadedRecords(now: Date) {
        var changed = false
        for (authToken, record) in recordsByAuthToken where record.ticket.isExpired(at: now) {
            recordsByAuthToken[authToken] = nil
            persistentAuthTokens.remove(authToken)
            Self.deleteRecord(authToken: authToken)
            changed = true
        }
        if changed {
            Self.storePersistentAuthTokenIndex(persistentAuthTokens)
        }
    }

    private func pruneExpiredPersistentRecordsIfDue(now: Date) {
        if let lastPersistentPruneAt,
           now.timeIntervalSince(lastPersistentPruneAt) < Self.persistentPruneInterval {
            return
        }
        lastPersistentPruneAt = now
        var changed = false
        for authToken in Array(persistentAuthTokens) {
            guard let record = recordsByAuthToken[authToken] ?? Self.loadRecord(authToken: authToken) else {
                persistentAuthTokens.remove(authToken)
                changed = true
                continue
            }
            if record.ticket.isExpired(at: now) {
                recordsByAuthToken[authToken] = nil
                persistentAuthTokens.remove(authToken)
                Self.deleteRecord(authToken: authToken)
                changed = true
            }
        }
        if changed {
            Self.storePersistentAuthTokenIndex(persistentAuthTokens)
        }
    }

    private func evictOldestPersistentRecordsIfNeeded(reservingSlots: Int) {
        let overflow = persistentAuthTokens.count + reservingSlots - Self.maxPersistentRecordCount
        guard overflow > 0 else { return }

        var candidates: [(authToken: String, issuedAt: Date)] = []
        for authToken in persistentAuthTokens {
            guard let record = recordsByAuthToken[authToken] ?? Self.loadRecord(authToken: authToken) else {
                persistentAuthTokens.remove(authToken)
                recordsByAuthToken[authToken] = nil
                Self.deleteRecord(authToken: authToken)
                continue
            }
            candidates.append((authToken: authToken, issuedAt: record.issuedAt))
        }

        let evicted = candidates
            .sorted { lhs, rhs in
                if lhs.issuedAt == rhs.issuedAt {
                    return lhs.authToken < rhs.authToken
                }
                return lhs.issuedAt < rhs.issuedAt
            }
            .prefix(overflow)
        for candidate in evicted {
            persistentAuthTokens.remove(candidate.authToken)
            recordsByAuthToken[candidate.authToken] = nil
            Self.deleteRecord(authToken: candidate.authToken)
        }
    }

    private static let recordKeychainService: String = {
        let bundleID = Bundle.main.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bundleID, !bundleID.isEmpty else {
            return "com.cmuxterm.mobile.attach-ticket-records"
        }
        return "com.cmuxterm.mobile.attach-ticket-records.\(bundleID)"
    }()
    private static let recordIndexKeychainAccount = "auth-token-index"
    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func recordKey(for authToken: String) -> String {
        let digest = SHA256.hash(data: Data(authToken.utf8))
        var output: [UInt8] = []
        output.reserveCapacity(SHA256.byteCount * 2)
        for byte in digest {
            output.append(hexDigits[Int(byte >> 4)])
            output.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func storeRecord(_ record: Record, authToken: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let key = recordKey(for: authToken)
        #if canImport(Security)
        storeRecordData(data, account: key)
        #endif
    }

    private static func loadRecord(authToken: String) -> Record? {
        let key = recordKey(for: authToken)
        #if canImport(Security)
        guard let data = loadRecordData(account: key) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
        #else
        return nil
        #endif
    }

    private static func deleteRecord(authToken: String) {
        let key = recordKey(for: authToken)
        #if canImport(Security)
        deleteRecordData(account: key)
        #endif
    }

    private static func loadPersistentAuthTokenIndex() -> Set<String> {
        #if canImport(Security)
        guard let data = loadRecordData(account: recordIndexKeychainAccount),
              let tokens = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return tokens
        #else
        return []
        #endif
    }

    private static func storePersistentAuthTokenIndex(_ tokens: Set<String>) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        #if canImport(Security)
        storeRecordData(data, account: recordIndexKeychainAccount)
        #endif
    }

    #if canImport(Security)
    private static func storeRecordData(_ data: Data, account: String) {
        let primaryStatus = storeRecordData(data, account: account, useDataProtectionKeychain: true)
        if primaryStatus == errSecMissingEntitlement {
            _ = storeRecordData(data, account: account, useDataProtectionKeychain: false)
        }
    }

    private static func storeRecordData(
        _ data: Data,
        account: String,
        useDataProtectionKeychain: Bool
    ) -> OSStatus {
        let query = recordKeychainQuery(account: account, useDataProtectionKeychain: useDataProtectionKeychain)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return errSecSuccess }
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(insert as CFDictionary, nil)
    }

    private static func loadRecordData(account: String) -> Data? {
        loadRecordData(account: account, useDataProtectionKeychain: true)
            ?? loadRecordData(account: account, useDataProtectionKeychain: false)
    }

    private static func loadRecordData(account: String, useDataProtectionKeychain: Bool) -> Data? {
        var query = recordKeychainQuery(account: account, useDataProtectionKeychain: useDataProtectionKeychain)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func deleteRecordData(account: String) {
        SecItemDelete(recordKeychainQuery(account: account, useDataProtectionKeychain: true) as CFDictionary)
        SecItemDelete(recordKeychainQuery(account: account, useDataProtectionKeychain: false) as CFDictionary)
    }

    private static func recordKeychainQuery(account: String, useDataProtectionKeychain: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: recordKeychainService,
            kSecAttrAccount as String: account,
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
    #endif

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBearerToken(byteCount: Int = 32) -> String {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        if status == errSecSuccess {
            return base64URLEncode(Data(bytes))
        }
        #endif
        return UUID().uuidString + UUID().uuidString
    }
}

struct MobileAttachTicketAuthorization {
    let ticket: CmxAttachTicket
    let createdWorkspaceIDs: Set<String>
    let createdTerminalIDs: Set<String>
}

enum MobileHostIdentity {
    private static let deviceIDKey = "mobileHost.deviceID"

    static func deviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceIDKey)
        return generated
    }

    static func displayName() -> String? {
        displayName(defaults: .standard)
    }

    /// The name the iOS app shows for this Mac during pairing.
    ///
    /// Uses the user's override from
    /// ``SettingCatalog/mobile``.`iOSPairingDisplayName` when it is set to a
    /// non-empty value, otherwise falls back to the Mac's name from System
    /// Settings (`Host.current().localizedName`).
    static func displayName(defaults: UserDefaults) -> String? {
        let key = SettingCatalog().mobile.iOSPairingDisplayName.userDefaultsKey
        if let override = defaults.string(forKey: key) {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return Host.current().localizedName
    }
}
