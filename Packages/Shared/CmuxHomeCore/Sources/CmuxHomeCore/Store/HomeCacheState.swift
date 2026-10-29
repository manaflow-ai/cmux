import Foundation

/// What one cache write holds, as the store and the view cache have it: the mirror's values as
/// they are (each copy is O(1), copy on write) plus the client's own state. The main actor builds
/// only this; ``HomeCache`` sorts, trims, compares and encodes it off the main actor
/// (speed-of-sound-DESIGN.md 3.5: a write costs the main actor nothing proportional to the store).
struct HomeCacheState: Sendable {
    var me: Participant?
    var conversations: [ConversationID: ConversationSummary] = [:]
    /// Each live window's messages, whole (the cache keeps the newest ``HomeCache/windowLimit``);
    /// an empty window is left out.
    var windows: [ConversationID: [Message]] = [:]
    var sends: [HomeCachedSend] = []
    var drafts: [ConversationID: String] = [:]
    var draftAttachments: [ConversationID: [HomeCachedDraftAttachment]] = [:]
    var scroll: [ConversationID: HomeScrollAnchor] = [:]

    init() {}

    /// A whole snapshot as a state (``HomeCache/save(_:)``).
    init(_ snapshot: HomeCacheSnapshot) {
        me = snapshot.me
        conversations = Dictionary(snapshot.conversations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        windows = snapshot.windows.filter { !$0.value.isEmpty }
        sends = snapshot.sends
        drafts = snapshot.drafts
        draftAttachments = snapshot.draftAttachments ?? [:]
        scroll = snapshot.scroll
    }

    /// The index file's snapshot: everything but the windows' messages, which go in their own
    /// files, named by `windowIDs`.
    var index: HomeCacheSnapshot {
        var snapshot = HomeCacheSnapshot()
        snapshot.me = me
        snapshot.conversations = conversations.values.sorted { $0.id.rawValue < $1.id.rawValue }
        snapshot.sends = sends
        snapshot.drafts = drafts
        snapshot.draftAttachments = draftAttachments.isEmpty ? nil : draftAttachments
        snapshot.scroll = scroll
        snapshot.windowIDs = windows.keys.sorted { $0.rawValue < $1.rawValue }
        return snapshot
    }
}
