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
    /// On disk only: the conversations whose window is in its own file beside the index
    /// (``HomeCache``), so a write touches only the windows that changed. Nil in a file written
    /// whole (an older build), whose `windows` are inline; nil in every loaded snapshot.
    var windowIDs: [ConversationID]?

    public init() {}

    /// Encodes the snapshot so equal values give equal bytes under `.sortedKeys`.
    ///
    /// `.sortedKeys` orders struct fields and `String`-keyed dictionaries only. ``ConversationID``
    /// is not `CodingKeyRepresentable`, so `Dictionary` writes the conversation-keyed fields
    /// (``windows``, ``drafts``, ``scroll``, ``draftAttachments``) as `[key, value, ...]` arrays in
    /// hash order. They are written here in that same shape, in key order, so every build still
    /// decodes them with the synthesized `init(from:)`.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: Any error the encoder throws.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(me, forKey: .me)
        try container.encode(conversations, forKey: .conversations)
        try container.encodeInKeyOrder(windows, forKey: .windows)
        try container.encode(sends, forKey: .sends)
        try container.encodeInKeyOrder(drafts, forKey: .drafts)
        try container.encodeInKeyOrder(scroll, forKey: .scroll)
        if let draftAttachments { try container.encodeInKeyOrder(draftAttachments, forKey: .draftAttachments) }
        try container.encodeIfPresent(windowIDs, forKey: .windowIDs)
    }
}
