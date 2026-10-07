import CmuxMobileWire

/// A refusal or failure from the Mac (`channel.refused`, `channel.closed`
/// with a code, `error`), or a local transfer failure, in the wire's codes.
public struct MobileClientError: Error, Hashable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool
    /// `details.reason` when the Mac gave one (`files.too_large`).
    public var reason: String?

    public init(code: String, message: String, retryable: Bool = false, reason: String? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.reason = reason
    }

    /// The session or channel ended without a word from the Mac.
    public static let disconnected = MobileClientError(code: "channel.closed", message: "the connection ended", retryable: true)

    init(refused frame: ChannelRefusedFrame) {
        self.init(code: frame.code, message: frame.message, retryable: frame.retryable,
                  reason: frame.details?["reason"]?.stringValue)
    }

    init(closed frame: ChannelClosedFrame) {
        let code = frame.code ?? "channel.closed"
        self.init(code: code, message: frame.message ?? "closed by the Mac",
                  retryable: code == "channel.closed" || code == "owner.unreachable")
    }
}
