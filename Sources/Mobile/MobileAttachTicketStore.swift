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
        pairingURLScheme: CmxPairingURLScheme? =
            CmxPairingURLSchemeResolver().resolved,
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
                routeDisclosureMode: routeDisclosureMode,
                pairingURLScheme: pairingURLScheme
            ).absoluteString
        case .ticketOnly:
            break
        case .some(let target):
            payload["attach_url"] = try attachURL(
                for: disclosedTicket,
                target: target,
                routeDisclosureMode: routeDisclosureMode,
                pairingURLScheme: pairingURLScheme
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
        routeDisclosureMode: CmxPairingRouteDisclosureMode,
        pairingURLScheme: CmxPairingURLScheme?
    ) throws -> URL {
        // Compatibility disclosure filters mixed snapshots down to the
        // canonical Tailscale subsequence and emits the plain v2 grammar.
        // The Mac pairing window requests this mode. The full-key v1 JSON
        // this branch used to emit base64-encoded the Mac's device id,
        // display name, and build metadata into a QR several versions denser
        // (23 vs 8 at ECC M) for fields the phone recovers post-handshake
        // from `mobile.host.status`; fielded clients have decoded v2 since
        // #5872. Explicit Iroh attach targets still use the EndpointID-only
        // representation below.
        if routeDisclosureMode == .legacyPrivateNetworkCompatibility,
           let url = tailscaleCompatibilityAttachURL(
               for: ticket,
               pairingURLScheme: pairingURLScheme
           ) {
            return url
        }

        if let pairingURL = CmxPairingQRCode().encode(
            ticket,
            routeDisclosureMode: routeDisclosureMode,
            pairingURLScheme: pairingURLScheme
        ), let url = URL(string: pairingURL) {
            return url
        }
        // Fallback for tickets the minimal grammar cannot express (workspace-
        // scoped, custom routes, loopback-only dev tickets): the compact
        // short-key v1 payload. The full ticket (including the token) still
        // rides in `payload(for:)["ticket"]` for RPC consumers.
        let compactTicket = try legacyCompatibleCompactTicket(
            ticket,
            routeDisclosureMode: routeDisclosureMode
        )
        return try compactAttachURL(
            for: compactTicket,
            routeDisclosureMode: routeDisclosureMode,
            pairingURLScheme: pairingURLScheme
        )
    }

    private func attachURL(
        for ticket: CmxAttachTicket,
        target: MobileAttachTarget,
        routeDisclosureMode _: CmxPairingRouteDisclosureMode,
        pairingURLScheme: CmxPairingURLScheme?
    ) throws -> URL {
        switch target {
        case .ticketOnly:
            throw MobileAttachTicketStoreError.invalidAttachURL
        case .simulatorInjection:
            if Self.hasOnlyIdentityOnlyIrohRoutes(ticket.routes) {
                return try compactAttachURL(
                    for: ticket,
                    routeDisclosureMode: .irohIdentityOnly,
                    pairingURLScheme: pairingURLScheme
                )
            }
            guard ticket.routes.allSatisfy({
                $0.kind == .debugLoopback && CmxLoopbackHost().matches($0)
            }) else {
                throw MobileAttachTicketStoreError.invalidAttachURL
            }
            let compactTicket = try legacyCompatibleCompactTicket(
                ticket,
                routeDisclosureMode: .legacyPrivateNetworkCompatibility
            )
            return try compactAttachURL(
                for: compactTicket,
                routeDisclosureMode: .legacyPrivateNetworkCompatibility,
                pairingURLScheme: pairingURLScheme
            )
        case .physicalDevice:
            guard ticket.routes.contains(where: {
                $0.kind == .iroh || $0.kind == .tailscale
            }) else {
                throw MobileAttachTicketStoreError.routeUnavailable
            }
            // A mixed Iroh/Tailscale ticket must retain an encrypted Iroh
            // bootstrap for a phone that selected LAN Only or iroh Only before
            // scanning. Use the compact grammar with LAN removed: released
            // phones know Iroh and Tailscale route kinds, while current phones
            // recover the LAN metadata from authenticated host status.
            if ticket.routes.contains(where: { $0.kind == .iroh }),
               ticket.routes.contains(where: { $0.kind == .tailscale }),
               let pairingURL = try mixedPhysicalDeviceCompatibilityAttachURL(
                   for: ticket,
                   pairingURLScheme: pairingURLScheme
               ) {
                return pairingURL
            }
            // A Tailscale-only ticket can use the smaller v2 grammar that old
            // iOS releases already understand.
            if let pairingURL = tailscaleCompatibilityAttachURL(
                for: ticket,
                pairingURLScheme: pairingURLScheme
            ) {
                return pairingURL
            }
            // A current client can bootstrap LAN Only from an identity-only
            // Iroh code; the broker supplies the LAN path inside encrypted Iroh.
            if ticket.routes.allSatisfy({ $0.kind == .iroh || $0.kind == .lan }),
               ticket.routes.contains(where: { $0.kind == .iroh }),
               ticket.routes.contains(where: { $0.kind == .lan }),
               let compactTicket = try? legacyCompatibleCompactTicket(
                   ticket,
                   routeDisclosureMode: .irohIdentityOnly
               ) {
                return try compactAttachURL(
                    for: compactTicket,
                    routeDisclosureMode: .irohIdentityOnly,
                    pairingURLScheme: pairingURLScheme
                )
            }
            if Self.hasOnlyIdentityOnlyIrohRoutes(ticket.routes) {
                guard let pairingURL = CmxPairingQRCode().encode(
                    ticket,
                    routeDisclosureMode: .irohIdentityOnly,
                    pairingURLScheme: pairingURLScheme
                ),
                let url = URL(string: pairingURL),
                let components = URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                ),
                let decoded = try? CmxPairingQRCode().decode(components),
                decoded.routes.count == ticket.routes.count,
                decoded.routes.first?.endpoint == ticket.routes.first?.endpoint else {
                    throw MobileAttachTicketStoreError.invalidAttachURL
                }
                return url
            }
            guard ticket.routes.allSatisfy({ route in
                if route.kind == .iroh {
                    guard case let .peer(_, pathHints) = route.endpoint else {
                        return false
                    }
                    return pathHints.isEmpty
                }
                return (route.kind == .tailscale || route.kind == .lan)
                    && !CmxLoopbackHost().matches(route)
            }) else {
                throw MobileAttachTicketStoreError.invalidAttachURL
            }
            // The compact grammar is the fallback when no released-compatible
            // Tailscale URL exists (for example an Iroh+LAN-only ticket).
            return try compactAttachURL(
                for: ticket,
                routeDisclosureMode: .legacyPrivateNetworkCompatibility,
                pairingURLScheme: pairingURLScheme
            )
        }
    }

    private func compactAttachURL(
        for ticket: CmxAttachTicket,
        routeDisclosureMode: CmxPairingRouteDisclosureMode,
        pairingURLScheme: CmxPairingURLScheme?
    ) throws -> URL {
        let coder = CmxAttachTicketCompactCoder()
        let data = try coder.encode(
            ticket,
            routeDisclosureMode: routeDisclosureMode
        )
        let payload = Self.base64URLEncode(data)
        guard let scheme = pairingURLScheme?.rawValue,
              let url = URL(
            string: "\(scheme)://attach?v=\(ticket.version)&payload=\(payload)"
        ),
        let decoded = try? coder.decode(data),
        decoded.routes == ticket.routes,
        decoded.authToken == nil else {
            throw MobileAttachTicketStoreError.invalidAttachURL
        }
        return url
    }

    private func mixedPhysicalDeviceCompatibilityAttachURL(
        for ticket: CmxAttachTicket,
        pairingURLScheme: CmxPairingURLScheme?
    ) throws -> URL? {
        let routes = try MobileAttachTarget.physicalDeviceCompatibilityQRRoutes(
            from: ticket.routes
        )
        guard routes.contains(where: { $0.kind == .iroh }),
              routes.contains(where: { $0.kind == .tailscale }) else {
            return nil
        }
        let compatibilityTicket = try CmxAttachTicket(
            version: ticket.version,
            workspaceID: ticket.workspaceID,
            terminalID: ticket.terminalID,
            macDeviceID: ticket.macDeviceID,
            macDisplayName: ticket.macDisplayName,
            macUserEmail: nil,
            macUserID: ticket.macUserID,
            macPairingCompatibilityVersion: ticket.macPairingCompatibilityVersion,
            macAppVersion: ticket.macAppVersion,
            macAppBuild: ticket.macAppBuild,
            routes: routes,
            expiresAt: nil,
            authToken: nil
        )
        return try compactAttachURL(
            for: compatibilityTicket,
            routeDisclosureMode: .legacyPrivateNetworkCompatibility,
            pairingURLScheme: pairingURLScheme
        )
    }

    private func legacyCompatibleCompactTicket(
        _ ticket: CmxAttachTicket,
        routeDisclosureMode: CmxPairingRouteDisclosureMode
    ) throws -> CmxAttachTicket {
        let routes = ticket.routes.compactMap { route -> CmxAttachRoute? in
            switch routeDisclosureMode {
            case .irohIdentityOnly:
                guard route.kind == .iroh,
                      case let .peer(identity, _) = route.endpoint else {
                    return nil
                }
                return try? CmxAttachRoute(
                    id: route.id,
                    kind: .iroh,
                    endpoint: .peer(identity: identity, pathHints: []),
                    priority: route.priority
                )
            case .legacyPrivateNetworkCompatibility:
                guard route.kind != .lan else { return nil }
                guard route.kind == .iroh else { return route }
                guard case let .peer(identity, _) = route.endpoint else { return nil }
                return try? CmxAttachRoute(
                    id: route.id,
                    kind: .iroh,
                    endpoint: .peer(identity: identity, pathHints: []),
                    priority: route.priority
                )
            }
        }
        guard !routes.isEmpty else {
            throw MobileAttachTicketStoreError.invalidAttachURL
        }
        return try CmxAttachTicket(
            version: ticket.version,
            workspaceID: ticket.workspaceID,
            terminalID: ticket.terminalID,
            macDeviceID: ticket.macDeviceID,
            macDisplayName: ticket.macDisplayName,
            macUserEmail: nil,
            macUserID: ticket.macUserID,
            macPairingCompatibilityVersion: ticket.macPairingCompatibilityVersion,
            macAppVersion: ticket.macAppVersion,
            macAppBuild: ticket.macAppBuild,
            routes: routes,
            expiresAt: nil,
            authToken: nil
        )
    }

    /// The minimal v2 Tailscale pairing URL for `ticket`, or `nil` when it
    /// carries no dialable Tailscale route or the v2 grammar cannot express
    /// it (workspace scope, a host needing escaping); callers fall back to
    /// the compact v1 payload so every ticket still has an attach URL.
    ///
    /// The disclosed sub-ticket keeps only the account binding (`ub`) and
    /// compatibility level (`pc`) the phone consults before dialing, drops
    /// the attach token, and reindexes the Tailscale routes to the canonical
    /// sequence the decoder resynthesizes, so mixed Iroh/loopback snapshots
    /// stay expressible.
    private func tailscaleCompatibilityAttachURL(
        for ticket: CmxAttachTicket,
        pairingURLScheme: CmxPairingURLScheme?
    ) -> URL? {
        guard let routes = try? MobileAttachTarget.canonicalTailscaleRoutes(
            from: ticket.routes
        ), !routes.isEmpty else {
            return nil
        }
        guard let compatibilityTicket = try? CmxAttachTicket(
            version: ticket.version,
            workspaceID: ticket.workspaceID,
            terminalID: ticket.terminalID,
            macDeviceID: ticket.macDeviceID,
            macDisplayName: ticket.macDisplayName,
            macUserEmail: nil,
            macUserID: ticket.macUserID,
            macPairingCompatibilityVersion: ticket.macPairingCompatibilityVersion,
            macAppVersion: ticket.macAppVersion,
            macAppBuild: ticket.macAppBuild,
            routes: routes,
            expiresAt: ticket.expiresAt,
            authToken: nil
        ),
        let pairingURL = CmxPairingQRCode().encode(
            compatibilityTicket,
            routeDisclosureMode: .legacyPrivateNetworkCompatibility,
            pairingURLScheme: pairingURLScheme
        ) else {
            return nil
        }
        return URL(string: pairingURL)
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
