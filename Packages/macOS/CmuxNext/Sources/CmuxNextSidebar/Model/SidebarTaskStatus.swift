public import CmuxNextDesign
import CmuxNextIcons
import Foundation

/// The task lane a person pinned a workspace to (Mark as Done, Set Workspace
/// Status, Cycle Workspace Status), as the sidebar draws it: classic cmux's
/// lanes, a glyph before the row's title and a line on the hover card. A
/// workspace without a pinned lane (automatic) draws none.
public nonisolated enum SidebarTaskStatus: String, CaseIterable, Hashable, Sendable {
    /// Not started.
    case todo
    /// Someone (a person or an agent) is on it.
    case working
    /// Waiting on the person: the loudest lane.
    case needsAttention
    /// Up for review.
    case review
    /// Finished.
    case done

    /// The SF Symbol the row draws before its title.
    public var symbol: String {
        switch self {
        case .todo: "circle"
        case .working: "circle.lefthalf.filled"
        case .needsAttention: "exclamationmark.circle.fill"
        case .review: "eye.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    /// The glyph's tint: the loudest for needs attention, muted once done.
    public var tint: GroupColor {
        switch self {
        case .todo, .done: .grey
        case .working: .blue
        case .needsAttention: .orange
        case .review: .green
        }
    }

    /// The row's leading glyph.
    public var glyph: WorkspaceIcon { .symbol(symbol, tint: tint) }

    /// The hover card's icon for the lane.
    var iconName: IconName {
        switch self {
        case .todo: .statusDot
        case .working: .statusInprogress
        case .needsAttention: .statusAttention
        case .review: .statusInfo
        case .done: .statusComplete
        }
    }

    /// The localized lane name.
    public var title: String {
        switch self {
        case .todo: String(localized: "sidebar.taskStatus.todo", defaultValue: "To Do", bundle: .module)
        case .working: String(localized: "sidebar.taskStatus.working", defaultValue: "Working", bundle: .module)
        case .needsAttention: String(localized: "sidebar.taskStatus.needsAttention", defaultValue: "Needs Attention", bundle: .module)
        case .review: String(localized: "sidebar.taskStatus.review", defaultValue: "In Review", bundle: .module)
        case .done: String(localized: "sidebar.taskStatus.done", defaultValue: "Done", bundle: .module)
        }
    }
}
