import Foundation

/// `ws-listen` (`ws-listen-v1`, cmux-tui spec/commands.md): a running owner that
/// started without its loopback page listener (the CLI or an agent started it)
/// opens it, and writes its credential to `<socket>.websocket.json` (0600). The
/// reply names the endpoint only, never the credential.
public struct WsListenRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var url: String
        public var pages: String?
        /// False when the listener already existed.
        public var opened: Bool
    }

    public static let command = "ws-listen"
    public static var requiredCapability: String? { DaemonCapabilities.shared.wsListen }
    /// One page origin the listener admits besides its own.
    public var allowOrigin: String?

    public init(allowOrigin: String?) {
        self.allowOrigin = allowOrigin
    }
}
