import CMUXMobileCore
import CmuxHive
import Foundation

/// Binds viewer routes to one authenticated local Tailscale control-plane
/// snapshot before a Stack bearer may be sent over the route.
///
/// The registry's route kind and an address-range check are not peer
/// authentication. This service resolves MagicDNS names through
/// `tailscale status --json`, verifies numeric addresses against the same
/// snapshot, and rewrites admitted routes to canonical numeric addresses.
/// Routes that cannot be proven are dropped so callers fail closed.
struct HiveTailscaleRouteAdmission: Sendable {
    /// The result consumed by the RPC runtime composition.
    struct Result: Sendable {
        /// Routes that are either non-Tailscale or control-plane-admitted.
        let routes: [CmxAttachRoute]
        /// Canonical numeric Tailscale hosts admitted by the snapshot.
        let verifiedTailscaleHosts: Set<String>
    }

    private let statusProvider: any TailscaleStatusProviding
    private let resolver: CmxTailscaleStatusPeerResolver

    /// Creates an admission service over the local Tailscale status provider.
    /// - Parameter statusProvider: Injectable daemon seam for tests.
    init(statusProvider: any TailscaleStatusProviding = SystemTailscaleStatusProvider()) {
        self.statusProvider = statusProvider
        self.resolver = CmxTailscaleStatusPeerResolver()
    }

    /// Admit the subset of routes that the local daemon can prove belongs to
    /// a remote peer. Non-Tailscale routes pass through unchanged.
    func admit(routes: [CmxAttachRoute]) async -> Result {
        guard routes.contains(where: { $0.kind == .tailscale }) else {
            return Result(routes: routes, verifiedTailscaleHosts: [])
        }
        guard let statusJSON = try? await statusProvider.statusJSON() else {
            return Result(
                routes: routes.filter { $0.kind != .tailscale },
                verifiedTailscaleHosts: []
            )
        }

        var admittedRoutes: [CmxAttachRoute] = []
        var verifiedHosts = Set<String>()
        for route in routes {
            guard route.kind == .tailscale else {
                admittedRoutes.append(route)
                continue
            }
            guard case let .hostPort(host, port) = route.endpoint,
                  let verifiedHost = verifiedHost(host, statusJSON: statusJSON),
                  let admittedRoute = try? CmxAttachRoute(
                      id: route.id,
                      kind: route.kind,
                      endpoint: .hostPort(host: verifiedHost, port: port),
                      priority: route.priority
                  ) else {
                continue
            }
            admittedRoutes.append(admittedRoute)
            verifiedHosts.insert(verifiedHost)
        }
        return Result(routes: admittedRoutes, verifiedTailscaleHosts: verifiedHosts)
    }

    private func verifiedHost(_ rawHost: String, statusJSON: Data) -> String? {
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
            ? String(rawHost.dropFirst().dropLast())
            : rawHost
        if let address = CmxTailscalePeerAddress(host) {
            guard (try? resolver.containsRemotePeerAddress(host, statusJSON: statusJSON)) == true else {
                return nil
            }
            return address.value
        }
        guard host.lowercased().hasSuffix(".ts.net"),
              let record = try? resolver.resolve(
                  magicDNSName: host,
                  statusJSON: statusJSON
              ) else {
            return nil
        }
        return record.preferredAddress.value
    }
}
