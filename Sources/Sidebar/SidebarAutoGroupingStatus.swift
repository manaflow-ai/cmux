import Foundation

/// A workspace's activity state for the Status grouping. Case order is the
/// section order: the state that most needs attention comes first.
enum SidebarAutoGroupingStatus: Int, CaseIterable, Comparable, Sendable {
    case needsInput
    case running
    case unread
    case idle
    case terminals

    /// Classifies one workspace. An agent waiting for input outranks a running
    /// agent, which outranks unread notifications; a workspace that has ever
    /// reported an agent state but is quiet is idle; everything else is a plain
    /// terminal workspace.
    init(agentLifecycleStates: [AgentHibernationLifecycleState], unreadCount: Int) {
        if agentLifecycleStates.contains(.needsInput) {
            self = .needsInput
        } else if agentLifecycleStates.contains(.running) {
            self = .running
        } else if unreadCount > 0 {
            self = .unread
        } else if !agentLifecycleStates.isEmpty {
            self = .idle
        } else {
            self = .terminals
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var sectionKey: String {
        switch self {
        case .needsInput: return "status:needs-input"
        case .running: return "status:running"
        case .unread: return "status:unread"
        case .idle: return "status:idle"
        case .terminals: return "status:terminals"
        }
    }

    var symbol: String {
        switch self {
        case .needsInput: return "exclamationmark.bubble"
        case .running: return "circle.dotted"
        case .unread: return "circle.fill"
        case .idle: return "checkmark.circle"
        case .terminals: return "terminal"
        }
    }

    var localizedTitle: String {
        switch self {
        case .needsInput:
            return String(localized: "sidebar.groupBy.section.needsInput", defaultValue: "Needs Input")
        case .running:
            return String(localized: "sidebar.groupBy.section.running", defaultValue: "Running")
        case .unread:
            return String(localized: "sidebar.groupBy.section.unread", defaultValue: "Unread")
        case .idle:
            return String(localized: "sidebar.groupBy.section.idle", defaultValue: "Idle")
        case .terminals:
            return String(localized: "sidebar.groupBy.section.terminals", defaultValue: "Terminals")
        }
    }
}
