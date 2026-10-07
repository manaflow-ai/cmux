public import CmuxLinkDirect
public import CmuxPairing
import Foundation

/// Joins what the phone knows into routes (pure): the Macs the trust store
/// vouches for, `_cmux._tcp` services found on the local link (TXT `host`
/// names the Mac, untrusted), and direct addresses the user saved (pinned
/// keys). An endpoint joins a Mac only under that Mac's verified key, so a
/// spoofed advertisement or a stale saved address can only fail a handshake.
public struct MobileRouteBook: Sendable, Hashable {
    public var trusted: [TrustedHostKey]
    public var discovered: [DirectDiscoveredHost]
    public var saved: [DirectEndpoint]

    public init(trusted: [TrustedHostKey] = [], discovered: [DirectDiscoveredHost] = [], saved: [DirectEndpoint] = []) {
        self.trusted = trusted
        self.discovered = discovered
        self.saved = saved
    }

    public func routes() -> [MobileHostRoute] {
        trusted.sorted { $0.host < $1.host }.compactMap { key in
            guard let pinned = DirectPublicKey(rawRepresentation: key.directKey) else { return nil }
            var targets: [DirectEndpoint.Target] = saved.filter { $0.hostKey == pinned }.map(\.target)
            targets += discovered.filter { $0.hostID == key.host }
                .map { $0.endpoint(pinning: pinned).target }
            var seen: Set<DirectEndpoint.Target> = []
            return MobileHostRoute(trusted: key, targets: targets.filter { seen.insert($0).inserted })
        }
    }

    /// Every Mac `state` names (own enrolled Macs and other accounts' hosts
    /// this device was accepted on), with its verified keys.
    public static func trustedHosts(in state: TrustStoreState, lookup: any TrustedKeyLookup) async -> [TrustedHostKey] {
        let hosts = Set(state.devices.values.compactMap(\.host) + state.remote.values.map(\.host))
        var keys: [TrustedHostKey] = []
        for host in hosts.sorted() {
            if let key = await lookup.hostKey(for: host) { keys.append(key) }
        }
        return keys
    }
}
