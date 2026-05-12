import Foundation

enum GoalSupervisionStatus: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case pending
    case active
    case paused
    case blocked
    case done
    case abandoned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pending:
            String(localized: "goals.status.pending", defaultValue: "Pending")
        case .active:
            String(localized: "goals.status.active", defaultValue: "Active")
        case .paused:
            String(localized: "goals.status.paused", defaultValue: "Paused")
        case .blocked:
            String(localized: "goals.status.blocked", defaultValue: "Blocked")
        case .done:
            String(localized: "goals.status.done", defaultValue: "Done")
        case .abandoned:
            String(localized: "goals.status.abandoned", defaultValue: "Abandoned")
        }
    }

    var symbolName: String {
        switch self {
        case .pending: "circle"
        case .active: "play.circle.fill"
        case .paused: "pause.circle"
        case .blocked: "exclamationmark.octagon"
        case .done: "checkmark.circle.fill"
        case .abandoned: "xmark.circle"
        }
    }
}

struct GoalSupervisionNote: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var body: String
    var createdAt: Date
}

struct GoalSupervisionRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var acceptanceCriteria: String
    var workspacePath: String?
    var status: GoalSupervisionStatus
    var createdAt: Date
    var updatedAt: Date
    var activeSince: Date?
    var accumulatedActiveSeconds: TimeInterval
    var notes: [GoalSupervisionNote]

    mutating func accumulateActiveTime(endingAt date: Date) {
        guard status == .active, let activeSince else { return }
        accumulatedActiveSeconds += max(0, date.timeIntervalSince(activeSince))
        self.activeSince = nil
    }

    func activeDuration(at date: Date) -> TimeInterval {
        guard status == .active, let activeSince else {
            return accumulatedActiveSeconds
        }
        return accumulatedActiveSeconds + max(0, date.timeIntervalSince(activeSince))
    }
}

struct GoalSupervisionSnapshot: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let acceptanceCriteria: String
    let workspacePath: String?
    let status: GoalSupervisionStatus
    let createdAt: Date
    let updatedAt: Date
    let activeSince: Date?
    let accumulatedActiveSeconds: TimeInterval
    let notes: [GoalSupervisionNote]

    func wallClockDuration(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(createdAt))
    }

    func activeDuration(at date: Date) -> TimeInterval {
        guard status == .active, let activeSince else {
            return accumulatedActiveSeconds
        }
        return accumulatedActiveSeconds + max(0, date.timeIntervalSince(activeSince))
    }

    var workspaceLabel: String {
        guard let workspacePath, !workspacePath.isEmpty else {
            return String(localized: "goals.workspace.none", defaultValue: "No workspace")
        }
        let lastPathComponent = (workspacePath as NSString).lastPathComponent
        return lastPathComponent.isEmpty ? workspacePath : lastPathComponent
    }
}
