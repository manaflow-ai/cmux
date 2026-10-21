import Foundation

/// The Priority view's strings (Resources/Localizable.xcstrings).
extension Strings {
    static var priorityTitle: String { String(localized: "sidebar.priority.title", defaultValue: "Priority", bundle: .module) }
    /// The bell's tooltip while the view is hidden or shown (the shortcut follows).
    static var priorityShow: String { String(localized: "sidebar.priority.show", defaultValue: "Show Priority View", bundle: .module) }
    static var priorityHide: String { String(localized: "sidebar.priority.hide", defaultValue: "Hide Priority View", bundle: .module) }
    /// After the bell's label while its dot shows: how many chats the dot stands for
    /// (`SidebarPriorityPanel.attentionCount`: waiting on the person, finished unseen, failed,
    /// lost or Red CI), so not "Needs you", which is only one of those states.
    static func priorityAttentionCount(_ count: Int) -> String {
        String(localized: "sidebar.priority.attentionCount", defaultValue: "Needs attention: \(count)", bundle: .module)
    }
    static var priorityEmpty: String {
        String(localized: "sidebar.priority.empty", defaultValue: "No agent chats right now", bundle: .module)
    }
    /// A working row's second line: what its agent does right now (`WorkspaceRowContent.now`).
    static func rowNow(_ step: String) -> String {
        String(localized: "sidebar.row.now", defaultValue: "Now: \(step)", bundle: .module)
    }
    static var priorityNeedsYou: String { String(localized: "sidebar.priority.state.needsYou", defaultValue: "Needs you", bundle: .module) }
    static var priorityDone: String { String(localized: "sidebar.priority.state.done", defaultValue: "Done", bundle: .module) }
    static var priorityFailed: String { String(localized: "sidebar.priority.state.failed", defaultValue: "Failed", bundle: .module) }
    static var priorityLost: String { String(localized: "sidebar.priority.state.lost", defaultValue: "Lost", bundle: .module) }
    /// Red CI: a pull request of the chat's has failing checks.
    static var priorityCIFailing: String {
        String(localized: "sidebar.priority.state.ciFailing", defaultValue: "CI failing", bundle: .module)
    }
    static var priorityWorking: String { String(localized: "sidebar.priority.state.working", defaultValue: "Working", bundle: .module) }
    /// A working chip with how long the turn has run, e.g. "Working 5m".
    static func priorityWorking(for duration: String) -> String {
        String(format: String(localized: "sidebar.priority.state.workingFor", defaultValue: "Working %@", bundle: .module), duration)
    }
    static var priorityIdle: String { String(localized: "sidebar.priority.state.idle", defaultValue: "Idle", bundle: .module) }
    static var priorityMarkRead: String { String(localized: "sidebar.priority.markRead", defaultValue: "Mark as Read", bundle: .module) }
    static var priorityPin: String { String(localized: "sidebar.priority.pin", defaultValue: "Pin to Priority", bundle: .module) }
    static var priorityUnpin: String { String(localized: "sidebar.priority.unpin", defaultValue: "Unpin from Priority", bundle: .module) }
    static var prioritySnooze: String { String(localized: "sidebar.priority.snooze", defaultValue: "Snooze for 1 Hour", bundle: .module) }
    static var priorityArchive: String { String(localized: "sidebar.priority.archive", defaultValue: "Archive", bundle: .module) }
}

extension SidebarPriorityEntry {
    /// The pin button's label and the row menu's pin row: what a press does to this chat.
    public var pinTitle: String { pinned ? Strings.priorityUnpin : Strings.priorityPin }
}

extension SidebarPriorityPanel {
    /// Why Toggle Priority View is unavailable while the view is not installed (`sidebar.priorityView.enabled`).
    public static var unavailableReason: String {
        String(localized: "sidebar.priority.off", defaultValue: "the Priority view is off; turn it on in the App Store or Settings", bundle: .module)
    }
}
