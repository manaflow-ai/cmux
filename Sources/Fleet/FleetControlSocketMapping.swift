import CmuxControlSocket
import CmuxFleet
import Foundation

@MainActor
enum FleetControlSocketMapping {
    static func state(_ state: FleetTaskState) -> ControlFleetTaskStateName {
        switch state {
        case .queued:
            .queued
        case .provisioning:
            .provisioning
        case .launching:
            .launching
        case .running:
            .running
        case .needsInput:
            .needsInput
        case .stalled:
            .stalled
        case .retryBackoff:
            .retryBackoff
        case .awaitingReview:
            .awaitingReview
        case .done:
            .done
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        }
    }

    static func state(_ state: ControlFleetTaskStateName) -> FleetTaskState {
        switch state {
        case .queued:
            .queued
        case .provisioning:
            .provisioning
        case .launching:
            .launching
        case .running:
            .running
        case .needsInput:
            .needsInput
        case .stalled:
            .stalled
        case .retryBackoff:
            .retryBackoff
        case .awaitingReview:
            .awaitingReview
        case .done:
            .done
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        }
    }

    static func fleetSnapshot(config: FleetConfig, counts: [FleetTaskState: Int], isRunning: Bool) -> ControlFleetSnapshot {
        var wireCounts: [ControlFleetTaskStateName: Int] = [:]
        for state in FleetTaskState.allCases {
            wireCounts[self.state(state)] = counts[state] ?? 0
        }
        return ControlFleetSnapshot(
            fleetID: config.id.rawValue,
            name: config.name,
            repoRoot: config.repoRoot,
            isRunning: isRunning,
            taskCounts: wireCounts
        )
    }

    static func taskSnapshot(fleetID: FleetID, task: FleetTask) -> ControlFleetTaskSnapshot {
        ControlFleetTaskSnapshot(
            taskID: task.id.rawValue,
            fleetID: fleetID.rawValue,
            source: task.sourceKind.rawValue,
            title: task.title,
            state: state(task.state),
            isBlocked: task.isBlocked,
            attempts: task.attempts,
            priority: task.priority,
            labels: task.labels,
            url: task.url?.absoluteString,
            workspaceID: task.workspaceID,
            surfaceID: task.surfaceID,
            directoryPath: task.directoryPath,
            branch: task.branch,
            pullRequest: task.pr.map {
                ControlFleetTaskPullRequest(
                    url: $0.url?.absoluteString,
                    status: $0.state?.rawValue ?? "unknown"
                )
            },
            lastError: task.lastError,
            createdAt: task.createdAt.timeIntervalSince1970,
            updatedAt: task.updatedAt.timeIntervalSince1970
        )
    }
}
