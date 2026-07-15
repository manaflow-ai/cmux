public import Foundation

/// The exact input bytes used to insert and submit a command in an interactive shell.
///
/// Multiline commands use bracketed paste so readline and ZLE insert the complete
/// script before a single trailing carriage return submits it. A single-line command
/// stays on the plain fast path.
public struct TerminalCommandSubmission: Equatable, Sendable {
    /// DEC 2004 sequence that begins a bracketed paste.
    public static let bracketedPasteStart = "\u{001B}[200~"

    /// DEC 2004 sequence that ends a bracketed paste.
    public static let bracketedPasteEnd = "\u{001B}[201~"

    /// Exact UTF-8 bytes to write to the terminal PTY.
    public let data: Data

    /// UTF-8 representation of ``data``, primarily useful for string-based startup seams.
    public var text: String {
        String(decoding: data, as: UTF8.self)
    }

    /// Builds the exact input bytes for a command and one submission event.
    ///
    /// A caller-provided trailing CR, LF, or CRLF is preserved on the single-line
    /// fast path. For multiline input, one trailing terminator is removed before
    /// wrapping the body in bracketed-paste markers and appending `submit` once.
    ///
    /// - Parameters:
    ///   - command: Shell input to insert and submit.
    ///   - submit: Character that submits the completed line. Defaults to CR.
    ///   - bracketedPasteSafe: Whether the target line editor supports bracketed paste.
    public init(command: String, submit: Character = "\r", bracketedPasteSafe: Bool = true) {
        let terminatorLength: Int
        if command.hasSuffix("\r\n") {
            terminatorLength = 2
        } else if command.hasSuffix("\r") || command.hasSuffix("\n") {
            terminatorLength = 1
        } else {
            terminatorLength = 0
        }

        let body = terminatorLength == 0
            ? command
            : String(command.unicodeScalars.dropLast(terminatorLength))
        let isMultiline = body.contains("\n") || body.contains("\r")

        let submission: String
        if bracketedPasteSafe && isMultiline {
            submission = Self.bracketedPasteStart + body + Self.bracketedPasteEnd + String(submit)
        } else if terminatorLength > 0 {
            submission = command
        } else {
            submission = command + String(submit)
        }
        self.data = Data(submission.utf8)
    }
}
