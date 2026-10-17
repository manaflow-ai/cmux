import Foundation

/// Where a conversation's unsent composer text lives between visits and
/// launches. Messages keeps one draft per conversation and lists it as
/// "Draft: …" in the conversation list.
@MainActor
public protocol ConversationDraftStorage: AnyObject {
    func draft(conversationID: String) -> String?
    /// `nil` removes the draft.
    func setDraft(_ text: String?, conversationID: String)
}

/// Drafts in `UserDefaults`, one key per conversation.
@MainActor
public final class ConversationUserDefaultsDraftStorage: ConversationDraftStorage {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "cmux.conversation.draft.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func draft(conversationID: String) -> String? {
        defaults.string(forKey: keyPrefix + conversationID)
    }

    public func setDraft(_ text: String?, conversationID: String) {
        if let text { defaults.set(text, forKey: keyPrefix + conversationID) } else { defaults.removeObject(forKey: keyPrefix + conversationID) }
    }
}

public enum ConversationDraft {
    /// Whether `text` counts as a draft (Messages ignores whitespace-only text).
    public static func isDraft(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The one-line list summary body: whitespace runs (newlines included)
    /// collapse to single spaces, as the list row shows a single line.
    public static func summaryText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
