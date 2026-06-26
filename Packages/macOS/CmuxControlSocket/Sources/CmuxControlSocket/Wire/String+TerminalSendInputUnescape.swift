import Foundation

extension String {
    /// This string unescaped for delivery to a terminal as send-input text.
    ///
    /// The literal escape sequences `\n` and `\r` both become a carriage return
    /// (the Enter key sends `\r`), and `\t` becomes a tab. This is the transform
    /// applied to the `send`, `send_workspace`, and `send_surface` line-protocol
    /// payloads before they reach the focused terminal panel, so the bytes
    /// written to the pty match the legacy v1 socket behavior exactly.
    public var terminalSendInputUnescaped: String {
        replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
    }
}
