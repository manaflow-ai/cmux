import Foundation

/// A row under New Message's To: field that runs instead of adding a token
/// (cmux Home's New Chief, Invite, "Invite … to <team>").
public struct ConversationComposeAction: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// SF Symbol drawn in the row's leading circle.
    public var systemImage: String

    public init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

/// One row of the list under To:: a section title, someone to add as a token,
/// or an action.
public enum ConversationComposeRow: Sendable, Hashable {
    /// A section's title ("Chiefs", "Team"); never picked.
    case header(String)
    case contact(ConversationContact)
    case action(ConversationComposeAction)

    /// False for a header: a tap and Return skip it.
    public var isSelectable: Bool {
        if case .header = self { return false }
        return true
    }
}

/// A directory whose New Message lists more than Messages' autocomplete: cmux
/// Home (the Mac's `HomeRecipientField`) shows its Chiefs and team in sections
/// before anything is typed, and action rows among the matches. Without one
/// the sheet is Messages' (nothing under To: until a letter is typed).
@MainActor
public protocol ConversationComposeListing: AnyObject {
    /// The list while nobody is chosen and nothing is typed. `excluding` holds
    /// the contact ids already added.
    func idleRows(excluding: [String]) -> [ConversationComposeRow]
    /// The list while text is typed: the directory's `matches` for `query`,
    /// with any action rows placed among them.
    func typedRows(matches: [ConversationContact], query: String) -> [ConversationComposeRow]
}
