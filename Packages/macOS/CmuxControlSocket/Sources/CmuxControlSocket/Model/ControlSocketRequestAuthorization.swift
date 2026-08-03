public import CmuxSettings

/// Authorization accepted for one control-socket request before its command
/// body crosses onto the main actor.
public struct ControlSocketRequestAuthorization: Sendable {
    /// Access mode captured atomically with the accepted connection generation.
    public let acceptedAccessMode: SocketControlMode

    /// Access-policy generation captured when the connection was accepted.
    public let generation: UInt64

    /// Password credential revision proved by the connection for this request.
    public let passwordAuthorization: SocketPasswordAuthorization

    /// Creates an immutable request authorization snapshot.
    public init(
        acceptedAccessMode: SocketControlMode,
        generation: UInt64,
        passwordAuthorization: SocketPasswordAuthorization
    ) {
        self.acceptedAccessMode = acceptedAccessMode
        self.generation = generation
        self.passwordAuthorization = passwordAuthorization
    }
}
