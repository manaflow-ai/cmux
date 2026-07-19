import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import Darwin
import Foundation

struct MobileShellRouteSelection: Sendable {
    let routeAuthPolicy: MobileShellRouteAuthPolicy

    init(routeAuthPolicy: MobileShellRouteAuthPolicy = MobileShellRouteAuthPolicy()) {
        self.routeAuthPolicy = routeAuthPolicy
    }

    /// Whether route selection must reject loopback routes. A loopback route
    /// (`.debugLoopback`, `127.0.0.1`) names the host it runs on, so on a
    /// physical device it can only ever reach the phone itself, never a remote
    /// Mac. Simulators and explicit mock-data UI tests host their test server at
    /// loopback, so those harnesses opt into it instead of weakening real-device
    /// reconnect for every debug build.
    var prefersNonLoopbackRoutes: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        !UITestConfig.mockDataEnabled
        #else
        false
        #endif
    }

    /// The first reachable host/port route to a Mac, in priority order.
    ///
    /// When `preferNonLoopback` is set (physical devices), a real route
    /// (`.tailscale` etc.) is always chosen over a `.debugLoopback` route even
    /// if the loopback route has a lower (more-preferred) priority, because a
    /// loopback route can never reach a remote Mac from a physical phone. A
    /// loopback route is used only when it is the sole supported route - the
    /// on-device XCUITest mock host, which serves a real listener on `127.0.0.1`
    /// inside the test runner. This is what lets a restored Mac (whose published
    /// routes include both `debug_loopback` and `tailscale`) actually connect
    /// over Tailscale instead of dialing the phone's own loopback and failing.
    func firstReconnectHostPortRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> (String, Int)? {
        reconnectHostPortRoutes(
            routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: preferNonLoopback
        ).first.map { ($0.host, $0.port) }
    }

    /// Ordered host/port reconnect candidates for a Mac, preserving the single-route
    /// preference policy but keeping fallbacks available for the same Mac.
    ///
    /// With `preferNonLoopback` (physical devices) the list never contains a
    /// `.debugLoopback` route — not even as the sole route. On a phone that
    /// address names the phone itself, so a stale backup carrying only the
    /// Mac's debug loopback route must fail closed instead of dialing a local
    /// port that can never reach the Mac. Explicit mock/simulator harnesses
    /// pass `false` and retain loopback for their in-process host.
    func reconnectHostPortRoutes(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> [MobileShellReconnectRouteCandidate] {
        let supportedKinds = Set(supportedKinds)
        let ordered = routes.sorted(by: routeSortsBefore)
        var seenEndpoints = Set<String>()

        func appendCandidates(
            where predicate: (CmxAttachRoute) -> Bool,
            to candidates: inout [MobileShellReconnectRouteCandidate]
        ) {
            for route in ordered {
                if !supportedKinds.isEmpty, !supportedKinds.contains(route.kind) {
                    continue
                }
                guard predicate(route), case let .hostPort(host, port) = route.endpoint else {
                    continue
                }
                let endpointKey = "\(host)\u{1F}\(port)"
                guard seenEndpoints.insert(endpointKey).inserted else { continue }
                candidates.append(MobileShellReconnectRouteCandidate(route: route, host: host, port: port))
            }
        }

        var candidates: [MobileShellReconnectRouteCandidate] = []
        if preferNonLoopback {
            // Prefer a Tailscale numeric IP over MagicDNS because it dials
            // without client DNS. Keep encrypted Tailscale routes ahead of
            // explicit plaintext manual-host fallbacks even when the manual
            // host is also a numeric IP.
            appendCandidates(where: { route in
                guard routeHasVerifiedTailscaleProvenance(route),
                      case let .hostPort(host, _) = route.endpoint else { return false }
                return CmxTailscalePeerAddress(host) != nil
            }, to: &candidates)
            appendCandidates(where: routeHasVerifiedTailscaleProvenance, to: &candidates)
            appendCandidates(where: { $0.kind != .debugLoopback }, to: &candidates)
            return candidates
        }
        appendCandidates(where: { _ in true }, to: &candidates)
        return candidates
    }

    /// Whether `host` is a numeric IP literal (IPv4 or IPv6) rather than a name
    /// that needs DNS resolution. Used to prefer directly-dialable IP routes over
    /// MagicDNS hostnames, which fail to resolve on some clients.
    func isIPLiteralHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let unbracketed = if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            String(trimmed.dropFirst().dropLast())
        } else {
            trimmed
        }

        var ipv4 = in_addr()
        if unbracketed.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return unbracketed.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    /// `true` on a physical iPhone/iPad; `false` in the simulator and in
    /// macOS-hosted package tests. Drives the loopback-pairing rejection.
    var isPhysicalDevice: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    func manualHostRoute(
        host: String,
        port: Int,
        isPhysicalDevice: Bool? = nil
    ) throws -> CmxAttachRoute {
        guard let normalizedHost = routeAuthPolicy.normalizedManualRouteHost(host) else {
            throw URLError(.badURL)
        }
        guard let routeKind = routeAuthPolicy.manualRouteKind(
            for: normalizedHost,
            allowsDebugLoopback: !(isPhysicalDevice ?? self.isPhysicalDevice)
        ) else {
            throw URLError(.badURL)
        }
        return try CmxAttachRoute(
            id: routeKind.rawValue,
            kind: routeKind,
            endpoint: .hostPort(host: normalizedHost, port: port)
        )
    }

    func manualHostRoute(
        host: String,
        port: Int,
        preserving sourceRoute: CmxAttachRoute?,
        isPhysicalDevice: Bool? = nil
    ) throws -> CmxAttachRoute {
        let inferredRoute = try manualHostRoute(host: host, port: port, isPhysicalDevice: isPhysicalDevice)
        guard let sourceRoute,
              case let .hostPort(sourceHost, sourcePort) = sourceRoute.endpoint,
              sourcePort == port,
              routeAuthPolicy.normalizedManualRouteHost(sourceHost) == routeAuthPolicy.normalizedManualRouteHost(host) else {
            return inferredRoute
        }
        if sourceRoute.kind == .manualHost
            || sourceRoute.kind == inferredRoute.kind
            || routeHasVerifiedTailscaleProvenance(sourceRoute) {
            return sourceRoute
        }
        return inferredRoute
    }

    func supportedRoutes(
        for ticket: CmxAttachTicket,
        supportedKinds: [CmxAttachTransportKind]
    ) -> [CmxAttachRoute] {
        let orderedRoutes = ticket.routes.sorted(by: routeSortsBefore)
        guard !supportedKinds.isEmpty else {
            return orderedRoutes
        }
        let supportedKinds = Set(supportedKinds)
        return orderedRoutes.filter { route in
            supportedKinds.contains(route.kind)
        }
    }

    func attachTicketIsUnexpired(_ ticket: CmxAttachTicket, now: Date) -> Bool {
        !ticket.isExpired(at: now)
    }

    private func routeSortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }

    /// Whether a structured route still carries a recognizable Tailscale endpoint.
    /// This is a provenance/ordering decision only; Tailscale routes remain
    /// ineligible for Stack bearer auth under ``MobileShellRouteAuthPolicy``.
    private func routeHasVerifiedTailscaleProvenance(_ route: CmxAttachRoute) -> Bool {
        guard route.kind == .tailscale,
              case let .hostPort(host, _) = route.endpoint else {
            return false
        }
        if CmxTailscalePeerAddress(host) != nil {
            return true
        }

        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = normalized.hasSuffix(".") ? String(normalized.dropLast()) : normalized
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.hasSuffix(".ts.net"), labels.count >= 3, name.count <= 253 else {
            return false
        }
        return labels.allSatisfy { label in
            !label.isEmpty
                && label.count <= 63
                && label.first != "-"
                && label.last != "-"
                && label.utf8.allSatisfy { byte in
                    (byte >= 0x61 && byte <= 0x7A)
                        || (byte >= 0x30 && byte <= 0x39)
                        || byte == 0x2D
                }
        }
    }
}
