#if DEBUG
/// The classified protocol and sanitized method token for one control-socket
/// command line, used to build the `socket.command.begin`/`.end` debug lines.
public struct SocketCommandDebugInfo: Equatable, Sendable {
    /// The wire protocol the line uses: `v1` (space-delimited) or `v2` (JSON).
    public let protocolName: String

    /// The sanitized command/method token (see
    /// ``ControlSocketCommandLog/sanitizedToken(_:)``).
    public let commandKey: String

    /// Creates a classified command-info value.
    /// - Parameters:
    ///   - protocolName: The wire protocol (`v1`/`v2`).
    ///   - commandKey: The sanitized command/method token.
    public init(protocolName: String, commandKey: String) {
        self.protocolName = protocolName
        self.commandKey = commandKey
    }
}
#endif
