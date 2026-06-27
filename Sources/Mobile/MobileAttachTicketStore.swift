import CMUXMobileCore
import CmuxSettings
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
    private static let defaultMaximumStoredTickets = 256

    private struct Record {
        let ticket: CmxAttachTicket
        let issuedAt: Date
        var createdWorkspaceIDs: Set<String> = []
        var createdTerminalIDs: Set<String> = []
    }

    private let maximumStoredTickets: Int
    private let lock = NSLock()
    private var recordsByAuthToken: [String: Record] = [:]

    init(maximumStoredTickets: Int = MobileAttachTicketStore.defaultMaximumStoredTickets) {
        self.maximumStoredTickets = max(1, maximumStoredTickets)
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
            recordsByAuthToken[authToken] = Record(ticket: ticket, issuedAt: now)
            enforceRecordLimit()
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
        guard let authToken = Self.normalizedAuthToken(authToken) else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        guard let record = recordsByAuthToken[authToken] else {
            return nil
        }
        if record.ticket.isExpired(at: now) {
            recordsByAuthToken.removeValue(forKey: authToken)
            return nil
        }
        return MobileAttachTicketAuthorization(
            ticket: record.ticket,
            createdWorkspaceIDs: record.createdWorkspaceIDs,
            createdTerminalIDs: record.createdTerminalIDs
        )
    }

    static func ticketMatchesCurrentMacAccount(
        ticket: CmxAttachTicket,
        currentUserID: String?,
        currentUserEmail: String?
    ) -> Bool {
        if let ticketUserID = normalizedNonEmpty(ticket.macUserID) {
            return normalizedNonEmpty(currentUserID) == ticketUserID
        }
        if let ticketEmail = normalizedEmail(ticket.macUserEmail) {
            return normalizedEmail(currentUserEmail) == ticketEmail
        }
        return false
    }

    func recordCreatedResources(
        authToken: String?,
        workspaceID: String?,
        terminalID: String?,
        now: Date = Date()
    ) {
        guard let authToken = Self.normalizedAuthToken(authToken) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard var record = recordsByAuthToken[authToken] else {
            return
        }
        if record.ticket.isExpired(at: now) {
            recordsByAuthToken.removeValue(forKey: authToken)
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
    }

    private func attachURL(for ticket: CmxAttachTicket) throws -> URL {
        // Preferred form: the minimal v2 pairing-code grammar — bare Tailscale
        // `host:port` routes in the URL query, nothing else. Everything the
        // older grammars carried has a better channel: bearer auth tokens stay
        // in the direct RPC payload, the display name and device id arrive
        // post-handshake from `mobile.host.status`, and a pairing QR never
        // expires. A DEBUG Mac's dev loopback route is dropped outright (a
        // scanned code must never point a phone at itself). The much shorter
        // plain-text URL also
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
    }

    private func enforceRecordLimit() {
        let overflowCount = recordsByAuthToken.count - maximumStoredTickets
        guard overflowCount > 0 else {
            return
        }

        let tokensToRemove = recordsByAuthToken
            .sorted { left, right in
                if left.value.issuedAt == right.value.issuedAt {
                    return left.key < right.key
                }
                return left.value.issuedAt < right.value.issuedAt
            }
            .prefix(overflowCount)
            .map(\.key)
        for token in tokensToRemove {
            recordsByAuthToken.removeValue(forKey: token)
        }
    }

    private static func normalizedAuthToken(_ authToken: String?) -> String? {
        let trimmed = authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        normalizedNonEmpty(value)?.lowercased()
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
    private static let sharedDeviceIDFileName = "mobile-host-device-id"
    private static let stableBundleIdentifier = "com.cmuxterm.app"

    static func deviceID() -> String {
        let stableDefaults = Bundle.main.bundleIdentifier == stableBundleIdentifier
            ? nil
            : UserDefaults(suiteName: stableBundleIdentifier)
        return deviceID(
            defaults: .standard,
            sharedIDURL: defaultSharedDeviceIDURL(),
            stableDefaults: stableDefaults,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static func deviceID(
        defaults: UserDefaults,
        sharedIDURL: URL?,
        stableDefaults: UserDefaults? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        if let id = readSharedDeviceID(from: sharedIDURL) {
            defaults.set(id, forKey: deviceIDKey)
            return id
        }

        if shouldPreferStableDefaults(bundleIdentifier: bundleIdentifier),
           let id = normalizedID(stableDefaults?.string(forKey: deviceIDKey)) {
            return settleSharedDeviceID(id, defaults: defaults, sharedIDURL: sharedIDURL)
        }

        if let id = normalizedID(defaults.string(forKey: deviceIDKey)) {
            return settleSharedDeviceID(id, defaults: defaults, sharedIDURL: sharedIDURL)
        }

        let generated = UUID().uuidString
        return settleSharedDeviceID(generated, defaults: defaults, sharedIDURL: sharedIDURL)
    }

    private static func defaultSharedDeviceIDURL(fileManager: FileManager = .default) -> URL? {
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let directory = appSupport.appendingPathComponent("cmux", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(sharedDeviceIDFileName)
    }

    private static func shouldPreferStableDefaults(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return bundleIdentifier != stableBundleIdentifier
    }

    private static func normalizedID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return uuid.uuidString
    }

    private static func readSharedDeviceID(from url: URL?) -> String? {
        guard let url,
              let existing = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return normalizedID(existing)
    }

    private static func settleSharedDeviceID(_ candidate: String, defaults: UserDefaults, sharedIDURL: URL?) -> String {
        guard let sharedIDURL else {
            defaults.set(candidate, forKey: deviceIDKey)
            return candidate
        }
        try? FileManager.default.createDirectory(
            at: sharedIDURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(candidate.utf8)
        if !FileManager.default.createFile(atPath: sharedIDURL.path, contents: data) {
            if let winner = readSharedDeviceID(from: sharedIDURL) {
                defaults.set(winner, forKey: deviceIDKey)
                return winner
            }
            try? data.write(to: sharedIDURL, options: .atomic)
        }
        let settled = readSharedDeviceID(from: sharedIDURL) ?? candidate
        defaults.set(settled, forKey: deviceIDKey)
        return settled
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
