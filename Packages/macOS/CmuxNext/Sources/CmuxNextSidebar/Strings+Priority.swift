import Foundation

/// The Priority view's strings (Resources/Localizable.xcstrings).
extension Strings {
    static var priorityTitle: String { String(localized: "sidebar.priority.title", defaultValue: "Priority", bundle: .l10n) }
    /// The bell's tooltip while the view is hidden or shown (the shortcut follows).
    static var priorityShow: String { String(localized: "sidebar.priority.show", defaultValue: "Show Priority View", bundle: .l10n) }
    static var priorityHide: String { String(localized: "sidebar.priority.hide", defaultValue: "Hide Priority View", bundle: .l10n) }
    /// After the bell's label while its dot shows: how many chats the dot stands for
    /// (`SidebarPriorityPanel.attentionCount`: waiting on the person, finished unseen, failed,
    /// lost or Red CI), so not "Needs you", which is only one of those states.
    static func priorityAttentionCount(_ count: Int) -> String {
        String(localized: "sidebar.priority.attentionCount", defaultValue: "Needs attention: \(count)", bundle: .l10n)
    }
    static var priorityEmpty: String {
        String(localized: "sidebar.priority.empty", defaultValue: "No agent chats right now", bundle: .l10n)
    }
    /// A working row's second line: what its agent does right now (`WorkspaceRowContent.now`).
    static func rowNow(_ step: String) -> String {
        String(localized: "sidebar.row.now", defaultValue: "Now: \(step)", bundle: .l10n)
    }
    static var priorityNeedsYou: String { String(localized: "sidebar.priority.state.needsYou", defaultValue: "Needs you", bundle: .l10n) }
    static var priorityDone: String { String(localized: "sidebar.priority.state.done", defaultValue: "Done", bundle: .l10n) }
    static var priorityFailed: String { String(localized: "sidebar.priority.state.failed", defaultValue: "Failed", bundle: .l10n) }
    static var priorityLost: String { String(localized: "sidebar.priority.state.lost", defaultValue: "Lost", bundle: .l10n) }
    /// Red CI: a pull request of the chat's has failing checks.
    static var priorityCIFailing: String {
        String(localized: "sidebar.priority.state.ciFailing", defaultValue: "CI failing", bundle: .l10n)
    }
    static var priorityWorking: String { String(localized: "sidebar.priority.state.working", defaultValue: "Working", bundle: .l10n) }
    /// A working chip with how long the turn has run, e.g. "Working 5m".
    static func priorityWorking(for duration: String) -> String {
        String(format: String(localized: "sidebar.priority.state.workingFor", defaultValue: "Working %@", bundle: .l10n), duration)
    }
    static var priorityIdle: String { String(localized: "sidebar.priority.state.idle", defaultValue: "Idle", bundle: .l10n) }
    static var priorityMarkRead: String { String(localized: "sidebar.priority.markRead", defaultValue: "Mark as Read", bundle: .l10n) }
    static var priorityPin: String { String(localized: "sidebar.priority.pin", defaultValue: "Pin to Priority", bundle: .l10n) }
    static var priorityUnpin: String { String(localized: "sidebar.priority.unpin", defaultValue: "Unpin from Priority", bundle: .l10n) }
    static var prioritySnooze: String { String(localized: "sidebar.priority.snooze", defaultValue: "Snooze for 1 Hour", bundle: .l10n) }
    static var priorityArchive: String { String(localized: "sidebar.priority.archive", defaultValue: "Archive", bundle: .l10n) }
    /// A row's VoiceOver actions: the chat moves one place in the Priority view and keeps it.
    static var priorityMoveEarlier: String { String(localized: "sidebar.priority.moveEarlier", defaultValue: "Move Earlier", bundle: .l10n) }
    static var priorityMoveLater: String { String(localized: "sidebar.priority.moveLater", defaultValue: "Move Later", bundle: .l10n) }
}

extension SidebarPriorityEntry {
    /// The pin button's label and the row menu's pin row: what a press does to this chat.
    public var pinTitle: String { pinned ? Strings.priorityUnpin : Strings.priorityPin }
}

extension SidebarPriorityPanel {
    /// Why Toggle Priority View is unavailable while the view is not installed (`sidebar.priorityView.enabled`).
    public static var unavailableReason: String {
        String(localized: "sidebar.priority.off", defaultValue: "the Priority view is off; turn it on in the App Store or Settings", bundle: .l10n)
    }
}
