internal import CmuxSettings

/// Immutable request retained across a bounded listener-start retry.
struct ListenerStartRequest: Equatable, Sendable {
    let socketPath: String
    let accessMode: SocketControlMode
    let preserveAcceptFailureStreak: Bool
}
