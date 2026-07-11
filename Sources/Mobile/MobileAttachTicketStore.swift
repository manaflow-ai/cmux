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

extension MobileAttachTicketStoreError: Equatable {}

final class MobileAttachTicketStore {
    private struct Record {
        let ticket: CmxAttachTicket
        let issuedAt: Date
        var createdWorkspaceIDs: Set<String> = []
        var createdTerminalIDs: Set<String> = []
    }

    private let lock = NSLock()
    private var recordsByAuthToken: [String: Record] = [:]

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
            macDisplayName: MobileHostIdentity.instanceDisplayName(),
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
        }
        return ticket
    }

    func payload(
        for ticket: CmxAttachTicket,
        target: MobileAttachTarget? = nil
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "ticket": try Self.jsonObject(ticket),
            "routes": ticket.routes.map(\.mobileHostJSONObject)
        ]
        switch target {
        case nil:
            payload["attach_url"] = try legacyAttachURL(for: ticket).absoluteString
        case .ticketOnly:
            break
        case .some(let target):
            payload["attach_url"] = try attachURL(for: ticket, target: target).absoluteString
        }
        // `expires_at` describes the minted attach token's lifetime (tickets
        // from `createTicket` always carry one). The QR payload itself encodes
        // no expiry; a displayed pairing code never goes stale.
        if let expiresAt = ticket.expiresAt {
            payload["expires_at"] = ISO8601DateFormatter().string(from: expiresAt)
        }
        return payload
    }

    /// Preserves the pre-target RPC contract for callers that omit `target`.
    /// Explicit targets use their stricter destination-specific encoders below.
    private func legacyAttachURL(for ticket: CmxAttachTicket) throws -> URL {
        if let pairingURL = CmxPairingQRCode().encode(ticket),
           let url = URL(string: pairingURL) {
            return url
        }
        let data = try CmxAttachTicketCompactCoder().encode(ticket)
        let payload = Self.base64URLEncode(data)
        guard let url = URL(
            string: "\(CmxPairingURLScheme.current)://attach?v=\(ticket.version)&payload=\(payload)"
        ) else {
            throw MobileAttachTicketStoreError.invalidAttachURL
        }
        return url
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
        guard let record = recordsByAuthToken[authToken],
              !record.ticket.isExpired(at: now) else {
            return nil
        }
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
    }

    private func attachURL(for ticket: CmxAttachTicket, target: MobileAttachTarget) throws -> URL {
        switch target {
        case .ticketOnly:
            throw MobileAttachTicketStoreError.invalidAttachURL
        case .simulatorInjection:
            let data = try CmxAttachTicketCompactCoder().encode(ticket)
            let payload = Self.base64URLEncode(data)
            guard let url = URL(
                string: "\(CmxPairingURLScheme.current)://attach?v=\(ticket.version)&payload=\(payload)"
            ) else {
                throw MobileAttachTicketStoreError.invalidAttachURL
            }
            return url
        case .physicalDevice:
            guard ticket.routes.allSatisfy({
                $0.kind == .tailscale && !CmxLoopbackHost().matches($0)
            }),
            let pairingURL = CmxPairingQRCode().encode(ticket),
            let url = URL(string: pairingURL),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let decoded = try? CmxPairingQRCode().decode(components),
            decoded.routes == ticket.routes else {
                // A phone URL never falls back to v1. If v2 cannot represent
                // the exact routes, fail instead of silently changing them.
                throw MobileAttachTicketStoreError.invalidAttachURL
            }
            return url
        }
    }

    private func pruneExpired(now: Date) {
        recordsByAuthToken = recordsByAuthToken.filter { !$0.value.ticket.isExpired(at: now) }
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
    private static let maximumDisplayNameUTF16Length = 128
    private static let maximumDisplayedBuildTagUTF16Length = 64

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

    /// Stable physical-device name. Device-level registry and backup rows use
    /// this value because they are shared by every tagged app instance.
    static func baseDisplayName() -> String? {
        baseDisplayName(defaults: .standard)
    }

    static func baseDisplayName(defaults: UserDefaults) -> String? {
        baseDisplayName(defaults: defaults, hostName: Host.current().localizedName)
    }

    static func baseDisplayName(
        defaults: UserDefaults,
        hostName: String?
    ) -> String? {
        let key = SettingCatalog().mobile.iOSPairingDisplayName.userDefaultsKey
        let baseName: String?
        if let override = defaults.string(forKey: key) {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                baseName = trimmed
            } else {
                baseName = hostName
            }
        } else {
            baseName = hostName
        }

        guard let baseName else { return nil }
        let trimmedName = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? nil : trimmedName
    }

    /// Per-app-instance name sent through tickets, authenticated status, and
    /// presence. Tagged DEBUG builds append their canonical launch tag while
    /// release and untagged builds keep the stable base name.
    static func instanceDisplayName() -> String? {
        instanceDisplayName(defaults: .standard)
    }

    static func instanceDisplayName(defaults: UserDefaults) -> String? {
        instanceDisplayName(
            defaults: defaults,
            hostName: Host.current().localizedName,
            buildTag: currentDebugBuildTag()
        )
    }

    static func instanceDisplayName(
        defaults: UserDefaults,
        hostName: String?,
        buildTag: String?
    ) -> String? {
        guard let trimmedName = baseDisplayName(defaults: defaults, hostName: hostName) else {
            return nil
        }
        let trimmedTag = buildTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedTag.isEmpty, trimmedTag != "default" else {
            return trimmedName
        }
        let originalSuffix = " (\(trimmedTag))"
        let unsuffixedName = trimmedName.hasSuffix(originalSuffix)
            ? String(trimmedName.dropLast(originalSuffix.count))
            : trimmedName
        let displayedTag = prefix(
            of: trimmedTag,
            fittingUTF16Length: maximumDisplayedBuildTagUTF16Length
        )
        let suffix = " (\(displayedTag))"
        let baseNameBudget = maximumDisplayNameUTF16Length - suffix.utf16.count
        let boundedName = prefix(of: unsuffixedName, fittingUTF16Length: baseNameBudget)
        return boundedName + suffix
    }

    /// Canonical app-instance tag used by registry and presence. This is the
    /// same launch tag that owns the tagged socket and bundle identity.
    static func instanceTag() -> String {
        SocketControlSettings.launchTag() ?? "default"
    }

    /// Returns the longest whole-character prefix that fits a UTF-16 wire limit.
    /// The cloud presence and paired-Mac APIs cap display names at 128 UTF-16
    /// code units, matching JavaScript's `String.length` measurement.
    private static func prefix(of value: String, fittingUTF16Length limit: Int) -> String {
        guard limit > 0 else { return "" }
        var result = ""
        var length = 0
        for character in value {
            let characterLength = String(character).utf16.count
            guard length + characterLength <= limit else { break }
            result.append(character)
            length += characterLength
        }
        return result
    }

    private static func currentDebugBuildTag() -> String? {
        #if DEBUG
        let tag = instanceTag()
        return tag == "default" ? nil : tag
        #else
        nil
        #endif
    }
}
