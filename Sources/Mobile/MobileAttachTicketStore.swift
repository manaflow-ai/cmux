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
    private var persistentAuthTokens: Set<String> = Self.loadPersistentAuthTokenIndex()

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

        pruneExpired(now: now)
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

        pruneExpired(now: now)
        guard let authToken = authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authToken.isEmpty else {
            return nil
        }
        let record = recordsByAuthToken[authToken] ?? Self.loadRecord(authToken: authToken)
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

    private func pruneExpired(now: Date) {
        recordsByAuthToken = recordsByAuthToken.filter { !$0.value.ticket.isExpired(at: now) }
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

    private static let recordKeychainService = "com.cmuxterm.mobile.attach-ticket-records"
    private static let recordIndexKeychainAccount = "auth-token-index"
    nonisolated(unsafe) private static var recordFallbackStore: [String: Data] = [:]

    private static func recordKey(for authToken: String) -> String {
        let digest = SHA256.hash(data: Data(authToken.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func storeRecord(_ record: Record, authToken: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let key = recordKey(for: authToken)
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: recordKeychainService,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecMissingEntitlement {
            recordFallbackStore[key] = data
            return
        }
        guard updateStatus == errSecItemNotFound else { return }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus == errSecMissingEntitlement {
            recordFallbackStore[key] = data
        }
        #else
        recordFallbackStore[key] = data
        #endif
    }

    private static func loadRecord(authToken: String) -> Record? {
        let key = recordKey(for: authToken)
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: recordKeychainService,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return try? JSONDecoder().decode(Record.self, from: data)
        }
        #endif
        guard let data = recordFallbackStore[key] else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func deleteRecord(authToken: String) {
        let key = recordKey(for: authToken)
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: recordKeychainService,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
        #endif
        recordFallbackStore[key] = nil
    }

    private static func loadPersistentAuthTokenIndex() -> Set<String> {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: recordKeychainService,
            kSecAttrAccount as String: recordIndexKeychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let tokens = try? JSONDecoder().decode(Set<String>.self, from: data) {
            return tokens
        }
        #endif
        guard let data = recordFallbackStore[recordIndexKeychainAccount],
              let tokens = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return tokens
    }

    private static func storePersistentAuthTokenIndex(_ tokens: Set<String>) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: recordKeychainService,
            kSecAttrAccount as String: recordIndexKeychainAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecMissingEntitlement {
            recordFallbackStore[recordIndexKeychainAccount] = data
            return
        }
        guard updateStatus == errSecItemNotFound else { return }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus == errSecMissingEntitlement {
            recordFallbackStore[recordIndexKeychainAccount] = data
        }
        #else
        recordFallbackStore[recordIndexKeychainAccount] = data
        #endif
    }

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
