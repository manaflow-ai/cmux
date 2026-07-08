public import Foundation

/// Builds pure board snapshots from Fleet engine values.
public struct FleetBoardProjection: Sendable {
    /// Creates a board projection helper.
    public init() {}

    /// Returns the board column for a Fleet task state.
    /// - Parameter state: The Fleet task state.
    public static func column(for state: FleetTaskState) -> FleetBoardColumn {
        switch state {
        case .queued:
            .queue
        case .provisioning, .launching, .running, .stalled, .retryBackoff:
            .running
        case .needsInput:
            .needsInput
        case .awaitingReview:
            .review
        case .done, .failed, .cancelled:
            .done
        }
    }

    /// Builds a value snapshot for the board.
    /// - Parameters:
    ///   - configs: Fleet configurations.
    ///   - isRunningByID: Running-state values keyed by Fleet identifier.
    ///   - tasksByFleetID: Tasks keyed by Fleet identifier.
    ///   - selectedFleetID: The requested selected Fleet.
    /// - Returns: A board snapshot with rows grouped into columns.
    public static func makeSnapshot(
        configs: [FleetConfig],
        isRunningByID: [FleetID: Bool],
        tasksByFleetID: [FleetID: [FleetTask]],
        selectedFleetID: FleetID?
    ) -> FleetBoardSnapshot {
        let summaries = configs
            .map { config in
                FleetBoardFleetSummary(
                    id: config.id,
                    name: config.name,
                    repoRoot: config.repoRoot,
                    isRunning: isRunningByID[config.id] ?? false
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let selected = summaries.first { $0.id == selectedFleetID } ?? summaries.first
        guard let selected else { return .empty }

        var columns = Dictionary(uniqueKeysWithValues: FleetBoardColumn.allCases.map { ($0, [FleetBoardRowSnapshot]()) })
        for task in (tasksByFleetID[selected.id] ?? []) {
            columns[Self.column(for: task.state), default: []].append(rowSnapshot(for: task))
        }
        for column in FleetBoardColumn.allCases {
            columns[column, default: []].sort { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
        }

        return FleetBoardSnapshot(selectedFleet: selected, fleets: summaries, columns: columns)
    }

    private static func rowSnapshot(for task: FleetTask) -> FleetBoardRowSnapshot {
        FleetBoardRowSnapshot(
            id: task.id,
            title: task.title,
            state: task.state,
            attempts: task.attempts,
            prURL: task.pr?.url,
            prLabel: task.pr?.number.map { "#\($0)" },
            lastError: task.lastError,
            updatedAt: task.updatedAt,
            canRetry: task.state.canUserRetry,
            canCancel: task.state.canUserCancel,
            hasWorkspace: task.workspaceID != nil
        )
    }
}
