import Foundation

/// What a Return in a composer does: send the draft or start a new line.
public enum ComposerReturnAction: Equatable, Sendable {
    case send
    case newline
}

/// Which Return conventions a composer follows.
///
/// - `chat` (agent chats, the chat conventions of ChatGPT and Claude on
///   iPhone): the on-screen keyboard's Return starts a new line and the send
///   button sends. A hardware keyboard's Return sends; Shift-Return or
///   Option-Return starts a new line.
/// - `terminal` (the terminal's "Send to ..." composer, SPEC 10.2): Return
///   sends the line to the program from either keyboard, as a shell expects.
///   Shift-Return or Option-Return on a hardware keyboard, or New Line in the
///   field's edit menu, starts a new line; a multi-line draft goes to the
///   program as one paste (`ComposerSubmit`).
public enum ComposerReturnStyle: Equatable, Sendable {
    case chat
    case terminal
}

/// The one place the composers decide what Return does (portable, unit tested).
public struct ComposerReturnPolicy: Equatable, Sendable {
    public let style: ComposerReturnStyle
    /// The draft grows with its text up to this many lines, then scrolls.
    public let maxLines: Int

    public init(style: ComposerReturnStyle, maxLines: Int) {
        self.style = style
        self.maxLines = max(maxLines, 1)
    }

    /// - Parameters:
    ///   - hardware: the Return came from a hardware keyboard (a key command),
    ///     not the on-screen keyboard.
    ///   - shift: Shift was held.
    ///   - option: Option (Alt) was held.
    public func action(hardware: Bool, shift: Bool = false, option: Bool = false) -> ComposerReturnAction {
        if hardware, shift || option { return .newline }
        switch style {
        case .chat: return hardware ? .send : .newline
        case .terminal: return .send
        }
    }

    /// The draft's height in lines: it grows with its text up to `maxLines`, then scrolls.
    public func visibleLines(contentLines: Int) -> Int {
        min(max(contentLines, 1), maxLines)
    }

    /// Whether the draft scrolls instead of growing.
    public func scrolls(contentLines: Int) -> Bool {
        contentLines > maxLines
    }
}
