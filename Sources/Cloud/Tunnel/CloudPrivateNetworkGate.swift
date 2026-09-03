import Foundation

/// The single hook every Cloud connection passes through before dialing a
/// machine on the private network.
///
/// ``VMClient`` calls it from each endpoint-minting method (attach, ssh,
/// cmux-remote, session attach, open-port), so the app's Machines panel, the
/// CLI's `vm` verbs, and session restore all trigger the same on-demand tunnel
/// start without knowing about it. Implementations never throw: the dial that
/// follows decides what a tunnel failure means for the user.
protocol CloudPrivateNetworkGate: Sendable {
    /// Returns once the private network is reachable, the attempt failed, or
    /// the readiness budget elapsed. Cheap when the tunnel is already up.
    func prepareForPrivateNetworkUse(_ use: CloudPrivateNetworkUse) async
}

/// What is about to dial the private network, for logging and consumer
/// accounting.
struct CloudPrivateNetworkUse: Sendable, Equatable {
    enum Purpose: String, Sendable {
        case ssh
        case attach
        case cmuxRemote = "cmux-remote"
        case sessionAttach = "session-attach"
        case openPort = "open-port"
    }

    let machineID: String
    let purpose: Purpose
}

/// The gate for builds and tests that do not manage a tunnel: dial straight
/// away, exactly as before the app-managed tunnel existed.
struct CloudPrivateNetworkNoopGate: CloudPrivateNetworkGate {
    func prepareForPrivateNetworkUse(_ use: CloudPrivateNetworkUse) async {}
}
