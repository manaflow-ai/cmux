/// The loopback endpoint returned by ``ControlRemotePTYControlling/startPTYBridge(sessionID:attachmentID:command:requireExisting:waitForReady:timeout:)``,
/// the package-side Sendable twin of CmuxRemoteWorkspace's
/// `RemotePTYBridgeServer.Endpoint`.
///
/// ``ControlRemotePTYWorker`` serializes its five fields onto the
/// `workspace.remote.pty_bridge` reply exactly as the legacy body did (`host`,
/// `port`, `token`, `session_id`, `attachment_id`). The app conformer maps the
/// concrete endpoint into this value so the package owns no PTY-bridge machinery.
public struct ControlRemotePTYBridgeEndpoint: Sendable, Equatable {
    /// The loopback host the bridge listens on.
    public let host: String

    /// The loopback port the bridge listens on.
    public let port: Int

    /// The bearer token the client must present to attach.
    public let token: String

    /// The persistent session identifier the bridge fronts.
    public let sessionID: String

    /// The attachment identifier this bridge serves.
    public let attachmentID: String

    /// Creates a bridge endpoint.
    ///
    /// - Parameters:
    ///   - host: The loopback host.
    ///   - port: The loopback port.
    ///   - token: The attach bearer token.
    ///   - sessionID: The persistent session identifier.
    ///   - attachmentID: The attachment identifier.
    public init(
        host: String,
        port: Int,
        token: String,
        sessionID: String,
        attachmentID: String
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.sessionID = sessionID
        self.attachmentID = attachmentID
    }
}
