public import AppKit

/// An editing command from the composer's context menu (`pane.edit {command}`), run as the web
/// view's own responder action so WebKit edits the field as its native menu did: the page never
/// reads the pasteboard, and a paste carries files as a real paste does.
public nonisolated enum AgentPaneEditCommand: String, Equatable, Sendable {
    case cut, copy, paste, pasteAsPlainText

    /// The web view's action for the command.
    public var selector: Selector {
        switch self {
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .pasteAsPlainText: NSSelectorFromString("pasteAsPlainText:")
        }
    }
}
