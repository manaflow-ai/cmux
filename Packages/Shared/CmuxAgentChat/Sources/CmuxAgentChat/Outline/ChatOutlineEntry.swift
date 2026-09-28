import Foundation

/// One user prompt in an agent conversation outline, with the start of the
/// agent's reply to it.
///
/// This is the per-turn list shared by every surface that navigates a
/// session by prompt: the terminal turn rail, keyboard turn navigation, and
/// any turn picker that needs the same prompt boundaries.
public struct ChatOutlineEntry: Identifiable, Sendable, Equatable {
    /// Maximum characters kept for ``title``.
    public static let titleLimit = 160
    /// Maximum characters kept for ``replyPreview``.
    public static let replyPreviewLimit = 240

    /// Stable identity: the first transcript message id of the prompt line.
    public let id: String

    /// Absolute transcript line index of the prompt.
    public let seq: Int

    /// Timestamp recorded for the prompt.
    public let timestamp: Date

    /// The prompt's first non-empty line, whitespace-collapsed and clipped to
    /// ``titleLimit`` characters.
    public let title: String

    /// The first one or two lines of the agent's first prose reply, or `nil`
    /// while the agent has not replied with prose yet.
    public let replyPreview: String?

    /// Creates an outline entry.
    public init(
        id: String,
        seq: Int,
        timestamp: Date,
        title: String,
        replyPreview: String? = nil
    ) {
        self.id = id
        self.seq = seq
        self.timestamp = timestamp
        self.title = title
        self.replyPreview = replyPreview
    }

    /// Whether ``title`` was clipped from a longer first line.
    public var isTitleClipped: Bool {
        title.count >= Self.titleLimit
    }

    func withReplyPreview(_ preview: String) -> ChatOutlineEntry {
        ChatOutlineEntry(id: id, seq: seq, timestamp: timestamp, title: title, replyPreview: preview)
    }

    func withTitle(_ title: String) -> ChatOutlineEntry {
        ChatOutlineEntry(id: id, seq: seq, timestamp: timestamp, title: title, replyPreview: replyPreview)
    }
}
