import Foundation

/// The Priority view's strings (Resources/Localizable.xcstrings).
extension Strings {
    static var priorityTitle: String { String(localized: "sidebar.priority.title", defaultValue: "Priority", bundle: .localizedModule) }
    /// The bell's tooltip while the view is hidden or shown (the shortcut follows).
    static var priorityShow: String { String(localized: "sidebar.priority.show", defaultValue: "Show Priority View", bundle: .localizedModule) }
    static var priorityHide: String { String(localized: "sidebar.priority.hide", defaultValue: "Hide Priority View", bundle: .localizedModule) }
    /// After the bell's label while its dot shows: how many chats the dot stands for
    /// (`SidebarPriorityPanel.attentionCount`: waiting on the person, finished unseen, failed,
    /// lost or Red CI), so not "Needs you", which is only one of those states.
    static func priorityAttentionCount(_ count: Int) -> String {
        String(localized: "sidebar.priority.attentionCount", defaultValue: "Needs attention: \(count)", bundle: .localizedModule)
    }
    static var priorityEmpty: String {
        String(localized: "sidebar.priority.empty", defaultValue: "No agent chats right now", bundle: .localizedModule)
    }
    /// A working row's second line: what its agent does right now (`WorkspaceRowContent.now`).
    static func rowNow(_ step: String) -> String {
        String(localized: "sidebar.row.now", defaultValue: "Now: \(step)", bundle: .localizedModule)
    }
    static var priorityNeedsYou: String { String(localized: "sidebar.priority.state.needsYou", defaultValue: "Needs you", bundle: .localizedModule) }
    static var priorityDone: String { String(localized: "sidebar.priority.state.done", defaultValue: "Done", bundle: .localizedModule) }
    static var priorityFailed: String { String(localized: "sidebar.priority.state.failed", defaultValue: "Failed", bundle: .localizedModule) }
    static var priorityLost: String { String(localized: "sidebar.priority.state.lost", defaultValue: "Lost", bundle: .localizedModule) }
    /// Red CI: a pull request of the chat's has failing checks.
    static var priorityCIFailing: String {
        String(localized: "sidebar.priority.state.ciFailing", defaultValue: "CI failing", bundle: .localizedModule)
    }
    static var priorityWorking: String { String(localized: "sidebar.priority.state.working", defaultValue: "Working", bundle: .localizedModule) }
    /// A working chip with how long the turn has run, e.g. "Working 5m".
    static func priorityWorking(for duration: String) -> String {
        String(format: String(localized: "sidebar.priority.state.workingFor", defaultValue: "Working %@", bundle: .localizedModule), duration)
    }
    static var priorityIdle: String { String(localized: "sidebar.priority.state.idle", defaultValue: "Idle", bundle: .localizedModule) }
    /// The header button with `sidebar.priorityView.filters`: every unseen result and failure read.
    static var priorityMarkAllRead: String {
        String(localized: "sidebar.priority.markAllRead", defaultValue: "Mark All as Read", bundle: .localizedModule)
    }
    /// The filter chips' names (`sidebar.priorityView.filters`).
    static var priorityFilterAll: String { String(localized: "sidebar.priority.filter.all", defaultValue: "All", bundle: .localizedModule) }
    static var priorityFilterWaiting: String {
        String(localized: "sidebar.priority.filter.waiting", defaultValue: "Waiting", bundle: .localizedModule)
    }
    static var priorityFilterUnread: String {
        String(localized: "sidebar.priority.filter.unread", defaultValue: "Unread", bundle: .localizedModule)
    }
    static var priorityFilterRunning: String {
        String(localized: "sidebar.priority.filter.running", defaultValue: "Running", bundle: .localizedModule)
    }
    /// What the list says when the picked filter has no rows.
    static var priorityFilterEmpty: String {
        String(localized: "sidebar.priority.filter.empty", defaultValue: "Nothing here right now", bundle: .localizedModule)
    }
    static var priorityMarkRead: String { String(localized: "sidebar.priority.markRead", defaultValue: "Mark as Read", bundle: .localizedModule) }
    static var priorityPin: String { String(localized: "sidebar.priority.pin", defaultValue: "Pin to Priority", bundle: .localizedModule) }
    static var priorityUnpin: String { String(localized: "sidebar.priority.unpin", defaultValue: "Unpin from Priority", bundle: .localizedModule) }
    static var prioritySnooze: String { String(localized: "sidebar.priority.snooze", defaultValue: "Snooze for 1 Hour", bundle: .localizedModule) }
    static var priorityArchive: String { String(localized: "sidebar.priority.archive", defaultValue: "Archive", bundle: .localizedModule) }
    /// An archived chat's hover button in the Archived fold: it lists again.
    static var priorityRestore: String { String(localized: "sidebar.priority.restore", defaultValue: "Restore", bundle: .localizedModule) }
    /// A row's VoiceOver actions: the chat moves one place in the Priority view and keeps it.
    static var priorityMoveEarlier: String { String(localized: "sidebar.priority.moveEarlier", defaultValue: "Move Earlier", bundle: .localizedModule) }
    static var priorityMoveLater: String { String(localized: "sidebar.priority.moveLater", defaultValue: "Move Later", bundle: .localizedModule) }
}

extension SidebarPriorityEntry {
    /// The pin button's label and the row menu's pin row: what a press does to this chat.
    public var pinTitle: String { pinned ? Strings.priorityUnpin : Strings.priorityPin }
}

extension SidebarPriorityPanel {
    /// Why Toggle Priority View is unavailable while the view is not installed (`sidebar.priorityView.enabled`).
    public static var unavailableReason: String {
        String(localized: "sidebar.priority.off", defaultValue: "the Priority view is off; turn it on in the App Store or Settings", bundle: .localizedModule)
    }
}
