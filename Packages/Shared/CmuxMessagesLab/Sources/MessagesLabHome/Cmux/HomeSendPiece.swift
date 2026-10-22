// cmux: one piece of a Home send, in the message box's order (Draft.pieces). Not a vendored file.
import CmuxHomeCore

/// A run of text or a prepared file of a send, as it sits in the message box.
enum HomeSendPiece: Sendable {
    case text(String)
    case file(LocalAttachment)

    /// The HomeStore part: the text, or the file's attachment reference.
    var part: MessagePart {
        switch self {
        case let .text(t): .text(t)
        case let .file(a): .attachment(a.ref)
        }
    }

    /// The text runs of PIECES, one per line.
    static func text(of pieces: [HomeSendPiece]) -> String {
        pieces.compactMap { if case let .text(t) = $0 { t } else { nil } }.joined(separator: "\n")
    }
}
