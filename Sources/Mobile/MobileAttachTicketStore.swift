import CMUXMobileCore
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
        routeDisclosureMode: CmxPairingRouteDisclosureMode = .legacyPrivateNetworkCompatibility,
        target: MobileAttachTarget? = nil,
        now: Date = Date()
    ) throws -> [String: Any] {
        let disclosedTicket = try ticket.authenticatedDisclosure(at: now)
        var payload: [String: Any] = [
            "ticket": try Self.jsonObject(disclosedTicket),
            "routes": disclosedTicket.routes.mobileHostJSONObjects(
                for: .authenticated,
                at: now
            )
        ]
        switch target {
        case nil:
            payload["attach_url"] = try attachURL(
                for: disclosedTicket,
                routeDisclosureMode: routeDisclosureMode
            ).absoluteString
        case .ticketOnly:
            break
        case .some(let target):
            payload["attach_url"] = try attachURL(
                for: disclosedTicket,
                target: target,
                routeDisclosureMode: routeDisclosureMode
            ).absoluteString
        }
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

    private func attachURL(
        for ticket: CmxAttachTicket,
        routeDisclosureMode: CmxPairingRouteDisclosureMode
    ) throws -> URL {
        // Released iOS clients understand the compact v2 Tailscale grammar.
        // Keep that representation only for an explicitly requested legacy
        // compatibility code. The default pairing window requests
        // `.irohIdentityOnly`, which falls through to the compact v1 envelope
        // below and contains the Mac's EndpointID without any path hints.
        if let pairingURL = CmxPairingQRCode().encode(
            ticket,
            routeDisclosureMode: routeDisclosureMode
        ), let url = URL(string: pairingURL) {
            return url
        }
        // Fallback for tickets the minimal grammar cannot express (workspace-
        // scoped, custom routes, loopback-only dev tickets): the compact
        // short-key v1 payload. The full ticket (including the token) still
        // rides in `payload(for:)["ticket"]` for RPC consumers.
        let data = try CmxAttachTicketCompactCoder().encode(
            ticket,
            routeDisclosureMode: routeDisclosureMode
        )
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

    private func attachURL(
        for ticket: CmxAttachTicket,
        target: MobileAttachTarget,
        routeDisclosureMode _: CmxPairingRouteDisclosureMode
    ) throws -> URL {
        switch target {
        case .ticketOnly:
            throw MobileAttachTicketStoreError.invalidAttachURL
        case .simulatorInjection:
            if Self.hasOnlyIdentityOnlyIrohRoutes(ticket.routes) {
                return try compactAttachURL(
                    for: ticket,
                    routeDisclosureMode: .irohIdentityOnly
                )
            }
            guard ticket.routes.allSatisfy({
                $0.kind == .debugLoopback && CmxLoopbackHost().matches($0)
            }) else {
                throw MobileAttachTicketStoreError.invalidAttachURL
            }
            return try compactAttachURL(
                for: ticket,
                routeDisclosureMode: .legacyPrivateNetworkCompatibility
            )
        case .physicalDevice:
            if Self.hasOnlyIdentityOnlyIrohRoutes(ticket.routes) {
                return try compactAttachURL(
                    for: ticket,
                    routeDisclosureMode: .irohIdentityOnly
                )
            }
            guard ticket.routes.allSatisfy({
                $0.kind == .tailscale && !CmxLoopbackHost().matches($0)
            }),
            let pairingURL = CmxPairingQRCode().encode(
                ticket,
                routeDisclosureMode: .legacyPrivateNetworkCompatibility
            ),
            let url = URL(string: pairingURL),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let decoded = try? CmxPairingQRCode().decode(components),
            decoded.routes == ticket.routes else {
                throw MobileAttachTicketStoreError.invalidAttachURL
            }
            return url
        }
    }

    private func compactAttachURL(
        for ticket: CmxAttachTicket,
        routeDisclosureMode: CmxPairingRouteDisclosureMode
    ) throws -> URL {
        let coder = CmxAttachTicketCompactCoder()
        let data = try coder.encode(
            ticket,
            routeDisclosureMode: routeDisclosureMode
        )
        let payload = Self.base64URLEncode(data)
        guard let url = URL(
            string: "\(CmxPairingURLScheme.current)://attach?v=\(ticket.version)&payload=\(payload)"
        ),
        let decoded = try? coder.decode(data),
        decoded.routes == ticket.routes,
        decoded.authToken == nil else {
            throw MobileAttachTicketStoreError.invalidAttachURL
        }
        return url
    }

    private static func hasOnlyIdentityOnlyIrohRoutes(_ routes: [CmxAttachRoute]) -> Bool {
        !routes.isEmpty && routes.allSatisfy { route in
            guard route.kind == .iroh,
                  case let .peer(_, pathHints) = route.endpoint else {
                return false
            }
            return pathHints.isEmpty
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
