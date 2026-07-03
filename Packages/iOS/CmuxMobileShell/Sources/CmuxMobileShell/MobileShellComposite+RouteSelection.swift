import CMUXMobileCore
import CmuxMobileShellModel
import Darwin
import Foundation

@MainActor
extension MobileShellComposite {
    /// Whether route selection should avoid loopback routes. A loopback route
    /// (`.debugLoopback`, `127.0.0.1`) names the host it runs on, so on a
    /// physical device it can only ever reach the phone itself, never a remote
    /// Mac. On the simulator `127.0.0.1` IS the host Mac, so loopback is valid
    /// (and is how the dev/UI-test mock host attaches).
    static var prefersNonLoopbackRoutes: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
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
    static func firstReconnectHostPortRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind],
        preferNonLoopback: Bool = false
    ) -> (String, Int)? {
        let supportedKinds = Set(supportedKinds)
        let ordered = routes.sorted(by: Self.routeSortsBefore)
        func firstHostPort(where predicate: (CmxAttachRoute) -> Bool) -> (String, Int)? {
            for route in ordered {
                if !supportedKinds.isEmpty, !supportedKinds.contains(route.kind) {
                    continue
                }
                guard predicate(route), case let .hostPort(host, port) = route.endpoint else {
                    continue
                }
                return (host, port)
            }
            return nil
        }
        if preferNonLoopback {
            // Among non-loopback routes, prefer one whose host is a numeric IP: a
            // raw tailscale/LAN IP is dialable without DNS, whereas a MagicDNS
            // hostname depends on the client having tailscale DNS active.
            if let ip = firstHostPort(where: { route in
                guard route.kind != .debugLoopback,
                      case let .hostPort(host, _) = route.endpoint else { return false }
                return Self.isIPLiteralHost(host)
            }) {
                return ip
            }
            if let real = firstHostPort(where: { $0.kind != .debugLoopback }) {
                return real
            }
        }
        return firstHostPort(where: { _ in true })
    }

    /// Whether `host` is a numeric IP literal (IPv4 or IPv6) rather than a name
    /// that needs DNS resolution. Used to prefer directly-dialable IP routes over
    /// MagicDNS hostnames, which fail to resolve on some clients.
    static func isIPLiteralHost(_ host: String) -> Bool {
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
    static var isPhysicalDevice: Bool {
        #if os(iOS) && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    static func manualHostRoute(host: String, port: Int) throws -> CmxAttachRoute {
        let routeKind = MobileShellRouteAuthPolicy.manualRouteKind(for: host)
        return try CmxAttachRoute(
            id: routeKind.rawValue,
            kind: routeKind,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    static func supportedRoutes(
        for ticket: CmxAttachTicket,
        supportedKinds: [CmxAttachTransportKind]
    ) -> [CmxAttachRoute] {
        let orderedRoutes = ticket.routes.sorted(by: Self.routeSortsBefore)
        guard !supportedKinds.isEmpty else {
            return orderedRoutes
        }
        let supportedKinds = Set(supportedKinds)
        return orderedRoutes.filter { route in
            supportedKinds.contains(route.kind)
        }
    }

    static func attachTicketIsUnexpired(_ ticket: CmxAttachTicket, now: Date) -> Bool {
        !ticket.isExpired(at: now)
    }
}
