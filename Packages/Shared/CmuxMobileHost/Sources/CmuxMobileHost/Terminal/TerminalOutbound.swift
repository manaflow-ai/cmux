import CmuxMobileWire
import CmuxTerminalStream

/// One queued item on a terminal channel's host-to-viewer direction.
enum TerminalOutbound: Sendable {
    case frame(TerminalFrame)
    case message(ChannelMessage)
    /// The owner's final word, then the channel closes.
    case close(code: String, message: String)

    /// Bytes this item holds against the viewer's window.
    var cost: Int {
        switch self {
        case .frame(let frame): frame.payload.count + 15
        case .message, .close: 0
        }
    }

    var isFrame: Bool {
        if case .frame = self { return true }
        return false
    }
}
