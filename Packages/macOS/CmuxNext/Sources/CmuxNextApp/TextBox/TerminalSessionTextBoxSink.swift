import CmuxNextTerminal
import Foundation

/// Sends a TextBox submit into a terminal session, in order with its typed keys (the session's
/// input queue): a paste, then a carriage return.
@MainActor
final class TerminalSessionTextBoxSink: TextBoxSink {
    private weak var session: TerminalSession?

    init(session: TerminalSession) { self.session = session }

    func paste(_ text: String) { session?.sendText(text) }

    func pressReturn() { session?.sendBytes(Data([0x0D])) }
}
