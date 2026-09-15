public import CMUXMobileCore
import Foundation

/// One saved or suggested path, with its related address families kept together.
public struct MobileComputerRouteGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let routes: [CmxAttachRoute]
    public var kind: CmxAttachTransportKind { routes[0].kind }

    /// Groups explicit peers; older ungrouped rows pair only when one IPv4 and one IPv6 are unambiguous.
    public static func groups(_ routes: [CmxAttachRoute]) -> [Self] {
        var seen: Set<String> = []
        let unique = routes.filter { seen.insert(endpointID($0)).inserted }
        let legacy = Dictionary(grouping: unique.filter { $0.kind == .tailscale && $0.groupID == nil }) {
            if case let .hostPort(_, port) = $0.endpoint { return port }
            return 0
        }
        var order: [String] = []
        var grouped: [String: [CmxAttachRoute]] = [:]
        for route in unique {
            var key = endpointID(route)
            if route.kind == .tailscale, let groupID = route.groupID {
                key = "tailscale-group:" + groupID
            } else if route.kind == .tailscale, case let .hostPort(_, port) = route.endpoint,
                      let peers = legacy[port], peers.count == 2,
                      Set(peers.compactMap { peer -> Bool? in
                          guard case let .hostPort(host, _) = peer.endpoint,
                                let address = CmxTailscalePeerAddress(host) else { return nil }
                          return address.value.contains(":")
                      }).count == 2 {
                key = peers.map(endpointID).sorted().joined(separator: "|")
            }
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(route)
        }
        return order.map { Self(id: $0, routes: grouped[$0] ?? []) }
    }

    /// Accept only numeric Tailscale TCP endpoints from an authenticated host snapshot.
    /// Iroh UDP hints and arbitrary LAN addresses cannot become raw Tailscale routes.
    public static func suggestions(_ routes: [CmxAttachRoute]) -> [Self] {
        let valid = routes.prefix(32).compactMap { route -> CmxAttachRoute? in
            guard route.kind == .tailscale, case let .hostPort(host, port) = route.endpoint,
                  let address = CmxTailscalePeerAddress(host) else { return nil }
            return try? CmxAttachRoute(id: "tailscale-\(address.value):\(port)", kind: .tailscale,
                endpoint: .hostPort(host: address.value, port: port), priority: route.priority,
                groupID: route.groupID)
        }
        return groups(valid).map { group in
            let routes = group.routes.compactMap { route in
                try? CmxAttachRoute(id: route.id, kind: route.kind, endpoint: route.endpoint,
                    priority: route.priority, groupID: group.id)
            }
            return Self(id: group.id, routes: routes)
        }
    }

    private static func endpointID(_ route: CmxAttachRoute) -> String {
        "\(route.kind.rawValue):\(route.endpoint)"
    }
}
