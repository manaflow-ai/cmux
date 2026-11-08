import Foundation

/// A tab the phone can jump to: Jump to Latest Unread and Jump to Last Prompt (the Mac's
/// `jumpToUnread` and `jumpToLastPrompt`, `NotificationActionCatalog`).
public struct TabAttentionPlace: Hashable, Sendable {
    public var workspaceID: String
    public var tabID: String
    /// When it happened on its Mac (the notification's post, the prompt's start); nil when
    /// the Mac did not say.
    public var at: Date?
    /// Orders places on one Mac that carry no time (the daemon's notification id).
    public var order: Int

    public init(workspaceID: String, tabID: String, at: Date?, order: Int = 0) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.at = at
        self.order = order
    }

    /// The Mac's refusals, as its actions say them (`MiscHandlerStrings`).
    public static let noUnread = "There are no unread notifications."
    public static let noPrompt = "No agent has been given a prompt yet."

    /// The newer of two places: by time, then by `order`. A place with a time is newer
    /// than one without.
    public static func newest(_ places: [TabAttentionPlace]) -> TabAttentionPlace? {
        places.max { lhs, rhs in
            switch (lhs.at, rhs.at) {
            case let (l?, r?) where l != r: l < r
            case (nil, _?): true
            case (_?, nil): false
            default: lhs.order < rhs.order
            }
        }
    }
}

/// What the phone knows of each Mac's unread tabs and prompted agents, from the daemon tree
/// and agent reports it already reads (`list-workspaces`, `list-agents`, `agent-changed`):
/// no command of its own.
@MainActor
public protocol TabAttentionBackend: AnyObject {
    /// The tab whose unread notification is newest on any of `macIDs`.
    func latestUnreadTab(on macIDs: [String]) -> TabAttentionPlace?
    /// The tab whose agent the person prompted last on any of `macIDs`.
    func lastPromptedTab(on macIDs: [String]) -> TabAttentionPlace?
}

#if DEBUG
/// Mock mode: the places a test or demo sets.
extension MockWorkspaceCreationBackend: TabAttentionBackend {
    public func latestUnreadTab(on macIDs: [String]) -> TabAttentionPlace? { attention.unread }
    public func lastPromptedTab(on macIDs: [String]) -> TabAttentionPlace? { attention.prompt }
}
#endif
