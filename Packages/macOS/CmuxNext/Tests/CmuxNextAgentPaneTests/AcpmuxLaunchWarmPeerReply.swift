import Foundation

/// Deterministic outcomes returned by the launch-warm test peer.
enum AcpmuxLaunchWarmPeerReply: Sendable {
    case success, failed, lost, unsupported
}
