public import AppKit
public import CoreGraphics
public import Foundation
public import Observation

/// One chat of acpmux's device-wide index as the session tree's history lists it: metadata only
/// (its key, title and last activity), never a transcript.
public nonisolated struct SidebarHistoryChat: Hashable, Sendable, Identifiable {
    /// acpmux's chat key (`harness:sessionId`), which Open Chat resumes.
    public let id: String
    public let title: String
    public let updatedAt: Date
    /// The acpmux harness family that owns this chat (for example `claude-code` or `codex`).
    /// History rows use it only for their identity mark; no transcript is loaded.
    public let harness: String?

    public init(id: String, title: String, updatedAt: Date, harness: String? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.harness = harness
    }
}

/// The session tree's chat history (`sidebar.sessionTree`, hq#2569 #6): the chats the user pinned,
/// listed above the tree, and a calm Earlier section under it with every chat no open workspace
/// shows (ended, closed or never opened here), newest first. Earlier lists one page at a time
/// (`limit`); Show More asks for the next. Built from the index's metadata, so it stays cheap with
/// thousands of chats: one pass over at most `limit` plus the live and pinned chats.
public nonisolated struct SidebarChatHistoryState: Hashable, Sendable {
    public var pinned: [SidebarHistoryChat] = []
    /// The page of Earlier shown; empty while folded.
    public var earlier: [SidebarHistoryChat] = []
    /// Earlier has a chat to list (its header shows, folded or not).
    public var hasEarlier = false
    /// More chats wait past the shown page (the Show More row).
    public var hasMore = false
    /// The user folded Earlier to its header.
    public var earlierFolded = false

    public init(pinned: [SidebarHistoryChat] = [], earlier: [SidebarHistoryChat] = [], hasEarlier: Bool = false,
                hasMore: Bool = false, earlierFolded: Bool = false) {
        self.pinned = pinned
        self.earlier = earlier
        self.hasEarlier = hasEarlier || !earlier.isEmpty
        self.hasMore = hasMore
        self.earlierFolded = earlierFolded
    }

    /// The history of `newest` (the index, newest first; read lazily, stopping once the page and
    /// one more are found). `live`: the chats an open workspace shows (the tree lists those).
    /// `pinned`: the pinned keys in pin order; `chat` finds a pinned chat outside the page.
    public static func make(newest: some Sequence<SidebarHistoryChat>, chat: (String) -> SidebarHistoryChat?,
                            live: Set<String>, pinned: [String], limit: Int, folded: Bool) -> SidebarChatHistoryState {
        var state = SidebarChatHistoryState(earlierFolded: folded)
        state.pinned = pinned.compactMap(chat)
        let skipped = live.union(pinned)
        let wanted = folded ? 0 : max(0, limit)
        for item in newest where !skipped.contains(item.id) {
            state.hasEarlier = true
            if state.earlier.count == wanted {
                state.hasMore = !folded
                break
            }
            state.earlier.append(item)
        }
        return state
    }

    // MARK: Heights (the list's layout and the views share them)

    /// The Pinned block: its header and one row per chat; 0 without pins.
    public func pinnedHeight(_ m: SidebarLayoutMetrics) -> CGFloat {
        pinned.isEmpty ? 0 : m.sectionHeaderHeight + CGFloat(pinned.count) * (m.rowHeight + m.rowSpacing)
    }

    /// The Earlier block: its header, the page's rows and the Show More row; 0 with nothing earlier.
    public func earlierHeight(_ m: SidebarLayoutMetrics) -> CGFloat {
        guard hasEarlier else { return 0 }
        guard !earlierFolded else { return m.sectionHeaderHeight }
        return m.sectionHeaderHeight + CGFloat(earlier.count + (hasMore ? 1 : 0)) * (m.rowHeight + m.rowSpacing)
    }
}

/// The session tree's chat history, live: nil while `sidebar.sessionTree` is off. The app's feed
/// (`SidebarChatHistoryFeed`) writes `state` from acpmux's chat index; the user's pins and the
/// Earlier fold are kept across launches here; the list reads both.
@Observable @MainActor
public final class SidebarChatHistory {
    public static let shared = SidebarChatHistory()

    public var state: SidebarChatHistoryState?
    /// Pinned chat keys, in pin order (the first pinned lists first).
    public private(set) var pinned: [String]
    public private(set) var earlierFolded: Bool
    /// How many Earlier chats show; Show More adds a page. Not kept: each launch starts calm.
    public private(set) var limit = SidebarChatHistory.pageSize
    /// Opens (resumes) a chat by key: the app's Open Chat path.
    @ObservationIgnored public var onOpen: (@MainActor (String) -> Void)?
    /// A history row's right-click menu, by chat key: the app's, built from the action registry
    /// (Pin or Unpin Chat on the row's chat, `SidebarChatHistoryFeed.bind`), so the row runs the
    /// registered action.
    @ObservationIgnored public var makeMenu: (@MainActor (String) -> NSMenu?)?
    @ObservationIgnored private let defaults: UserDefaults

    public static let pageSize = 20
    static let pinnedKey = "cmux.next.sidebar.sessionTree.pinnedChats"
    static let foldedKey = "cmux.next.sidebar.sessionTree.earlierFolded"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinned = defaults.stringArray(forKey: Self.pinnedKey) ?? []
        earlierFolded = defaults.bool(forKey: Self.foldedKey)
    }

    public func isPinned(_ key: String) -> Bool { pinned.contains(key) }

    /// Pins `key` (last among the pins) or unpins it.
    public func setPinned(_ key: String, _ pin: Bool) {
        guard pin != isPinned(key) else { return }
        if pin { pinned.append(key) } else { pinned.removeAll { $0 == key } }
        defaults.set(pinned, forKey: Self.pinnedKey)
    }

    public func toggleEarlier() {
        earlierFolded.toggle()
        defaults.set(earlierFolded, forKey: Self.foldedKey)
    }

    /// Show More: the next page of Earlier.
    public func showMore() { limit += Self.pageSize }

    public func open(_ key: String) { onOpen?(key) }
}
