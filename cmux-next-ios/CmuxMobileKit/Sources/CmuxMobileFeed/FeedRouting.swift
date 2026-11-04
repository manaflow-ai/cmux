#if os(iOS)
import CmuxMobileAgentChat
import SwiftUI

// The Feed's rows are UIKit cells (FeedRowCell, FeedRowLayout, FeedCollection:
// verify/feed-perf-20261022.md). What the rows and the screen share:

/// What every Feed row shares: the store and the screen's actions. One
/// object for the screen's life.
@MainActor
final class FeedRowContext {
    let store: FeedStore
    /// Opens an event (set by the Feed screen; it owns the navigation path).
    var open: (FeedItem) -> Void = { _ in }

    init(store: FeedStore) {
        self.store = store
    }
}

/// Where Feed actions that leave the Feed go (Reply sends into the tab's agent).
@MainActor
public final class FeedRouting {
    public static let shared = FeedRouting()
    /// Reply: the prompt goes to the item's chat, or why it can't.
    public enum ReplyOutcome {
        case sent(AgentChatStore)
        case failed(String)
    }
    var sendPrompt: ((FeedItem, String) -> ReplyOutcome)?
    /// Reply to a terminal agent's event: typed into that terminal's agent on
    /// its Mac (nil: sent; else why not). Set by the shell.
    public var replyToTerminal: ((FeedItem, String) async -> String?)?
    /// Opens a terminal agent's tab on the Workspaces tab (set by the shell).
    public var openTerminal: ((FeedItem) -> Void)?
    /// Clear All Notifications on the linked Mac (nil: no Mac can clear now).
    public var clearAllNotifications: (() async throws -> Void)?
    /// Mark All Notifications as Read on every linked Mac (nil: no Mac can now): the number
    /// of tabs it read.
    public var markAllNotificationsRead: (() async throws -> Int)?
}
#endif
