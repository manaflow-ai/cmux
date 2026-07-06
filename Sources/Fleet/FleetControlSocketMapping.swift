import CmuxControlSocket
import CmuxFleet
import Foundation

// Maps Fleet engine values to and from their control-socket wire shapes.

extension FleetTaskState {
    /// The control-socket wire name for this engine task state.
    var controlStateName: ControlFleetTaskStateName {
        switch self {
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
}

extension ControlFleetTaskStateName {
    /// The Fleet engine task state for this wire name.
    var fleetTaskState: FleetTaskState {
        switch self {
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
}

extension ControlFleetSnapshot {
    /// Builds the wire snapshot for one fleet.
    init(config: FleetConfig, counts: [FleetTaskState: Int], isRunning: Bool) {
        var wireCounts: [ControlFleetTaskStateName: Int] = [:]
        for state in FleetTaskState.allCases {
            wireCounts[state.controlStateName] = counts[state] ?? 0
        }
        self.init(
            fleetID: config.id.rawValue,
            name: config.name,
            repoRoot: config.repoRoot,
            isRunning: isRunning,
            taskCounts: wireCounts
        )
    }
}

extension ControlFleetTaskSnapshot {
    /// Builds the wire snapshot for one task.
    init(fleetID: FleetID, task: FleetTask) {
        self.init(
            taskID: task.id.rawValue,
            fleetID: fleetID.rawValue,
            source: task.sourceKind.rawValue,
            title: task.title,
            state: task.state.controlStateName,
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
