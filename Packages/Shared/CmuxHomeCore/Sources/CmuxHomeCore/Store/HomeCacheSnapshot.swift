import Foundation

/// What the cache holds (plans/cmux-next/home-state-ownership.md section 4):
/// the owner's last inbox and the tail of each opened conversation, as the
/// mirror had them, plus the client's own state (unsent sends, drafts, scroll
/// anchors). A copy, never a writer: the owner's answers overwrite it.
public struct HomeCacheSnapshot: Hashable, Sendable, Codable {
    public static let currentVersion = 1

    public var version = HomeCacheSnapshot.currentVersion
    public var me: Participant?
    public var conversations: [ConversationSummary] = []
    /// The newest messages of each conversation the reader opened (at most
    /// `HomeCache.windowLimit`), ascending.
    public var windows: [ConversationID: [Message]] = [:]
    public var sends: [HomeCachedSend] = []
    public var drafts: [ConversationID: String] = [:]
    public var scroll: [ConversationID: HomeScrollAnchor] = [:]
    /// The attachments in each compose field, in order. Optional: a cache
    /// written before drafts kept them still decodes.
    public var draftAttachments: [ConversationID: [HomeCachedDraftAttachment]]?
    /// The Chief conversation Home showed last (the Chief tab's), so the next launch draws it at
    /// its first frame, before the owner answers (CMUX-571). Optional: an older cache decodes.
    public var chief: ConversationID?
    /// On disk only: the conversations whose window is in its own file beside the index
    /// (``HomeCache``), so a write touches only the windows that changed. Nil in a file written
    /// whole (an older build), whose `windows` are inline; nil in every loaded snapshot.
    var windowIDs: [ConversationID]?

    public init() {}
}
