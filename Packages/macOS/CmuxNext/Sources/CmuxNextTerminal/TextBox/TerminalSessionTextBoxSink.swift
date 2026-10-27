package import Foundation

/// Sends a TextBox submit into a terminal session, in order with its typed keys (the session's
/// input queue): a paste, then a carriage return.
@MainActor
package final class TerminalSessionTextBoxSink: TextBoxSink {
    private weak var session: TerminalSession?

    package init(session: TerminalSession) { self.session = session }

    package func paste(_ text: String) { session?.sendText(text) }

    package func pressReturn() { session?.sendBytes(Data([0x0D])) }
}
