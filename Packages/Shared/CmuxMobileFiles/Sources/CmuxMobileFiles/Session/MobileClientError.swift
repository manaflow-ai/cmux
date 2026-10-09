import CmuxMobileLink
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

    /// The shared session's failure in the files family's shape.
    public init(_ error: MobileLinkClientError) {
        switch error {
        case .helloRejected(let code, let message): self.init(code: code, message: message)
        case .refused(let code, let message, let retryable): self.init(code: code, message: message, retryable: retryable)
        case .linkLost: self = .disconnected
        case .protocolViolation(let message): self.init(code: "proto.bad_record", message: message)
        case .closed: self.init(code: "channel.closed", message: "the session was closed")
        }
    }

    /// Any error from the session or a channel, mapped.
    static func from(_ error: any Error) -> any Error {
        if let link = error as? MobileLinkClientError { return MobileClientError(link) }
        return error
    }

    init(closed frame: ChannelClosedFrame) {
        let code = frame.code ?? "channel.closed"
        self.init(code: code, message: frame.message ?? "closed by the Mac",
                  retryable: code == "channel.closed" || code == "owner.unreachable")
    }
}
