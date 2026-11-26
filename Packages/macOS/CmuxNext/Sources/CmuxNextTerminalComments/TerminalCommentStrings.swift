import CmuxNextCompat
import Foundation

/// The terminal selection comment's text (Resources/TerminalComments.xcstrings).
public struct TerminalCommentStrings {
    public init() {}
    public static var menuTitle: String { text("terminalComments.menuTitle", "Comment…") }
    public static var noChat: String { text("terminalComments.noChat", "This workspace has no agent chat to send the comment to.") }
    public static var gesture: String { text("terminalComments.gesture", "A comment on a terminal selection needs a click or a key in cmux.") }
    public static var terminal: String { text("terminalComments.terminal", "Terminal") }
    static var header: String { text("terminalComments.header", "Comments") }
    static var sent: String { text("terminalComments.sent", "Sent") }
    static var waiting: String { text("terminalComments.waiting", "Waiting for the agent's reply…") }
    static var resolve: String { text("terminalComments.resolve", "Resolve") }
    public static var notSent: String { text("terminalComments.notSent", "The comment was not sent to the chat.") }

    private static func text(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "TerminalComments", bundle: .module.inAppLanguage)
    }
}
