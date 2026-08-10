import Foundation

/// Serializes workspace Simulator selection intents so stream RPCs never overlap.
@MainActor
final class MobileSimulatorStreamSelectionCoordinator {
    enum Operation: Equatable {
        case start(panelID: String, workspaceID: String)
        case stop(panelID: String, workspaceID: String)
    }

    private struct Selection: Equatable {
        let panelID: String
        let workspaceID: String
    }

    private struct Intent {
        let target: Selection?
    }

    typealias PerformOperation = @MainActor (Operation) async -> Void

    private let performOperation: PerformOperation
    private var pendingIntent: Intent?
    private var activeSelection: Selection?
    private(set) var transitionTask: Task<Void, Never>?

    init(performOperation: @escaping PerformOperation) {
        self.performOperation = performOperation
    }

    func requestTransition(
        from previousPanelID: String?,
        to targetPanelID: String?,
        workspaceID: String
    ) {
        let previous = previousPanelID.map { Selection(panelID: $0, workspaceID: workspaceID) }
        let target = targetPanelID.map { Selection(panelID: $0, workspaceID: workspaceID) }
        if activeSelection == nil {
            activeSelection = previous
        }
        pendingIntent = Intent(target: target)
        startDrainIfNeeded()
    }

    func cancel() {
        pendingIntent = nil
        transitionTask?.cancel()
    }

    func waitForIdle() async {
        while let task = transitionTask {
            await task.value
        }
    }

    private func startDrainIfNeeded() {
        guard transitionTask == nil else { return }
        transitionTask = Task { @MainActor [weak self] in
            await self?.drainPendingTransitions()
        }
    }

    private func drainPendingTransitions() async {
        while !Task.isCancelled, let intent = pendingIntent {
            pendingIntent = nil
            let previous = activeSelection

            if let previous, previous != intent.target {
                await performOperation(
                    .stop(panelID: previous.panelID, workspaceID: previous.workspaceID)
                )
                activeSelection = nil
                guard !Task.isCancelled else { break }
            }

            // A newer intent that arrived while the stop was in flight owns
            // the next start. Skipping this target avoids transient stale RPCs.
            guard pendingIntent == nil else { continue }
            guard let target = intent.target, target != activeSelection else { continue }

            await performOperation(
                .start(panelID: target.panelID, workspaceID: target.workspaceID)
            )
            activeSelection = target

            if Task.isCancelled {
                // Cancellation can race an already-sent start RPC. Stop the
                // accepted target before releasing coordinator ownership.
                await performOperation(
                    .stop(panelID: target.panelID, workspaceID: target.workspaceID)
                )
                activeSelection = nil
                break
            }
        }

        transitionTask = nil
        if pendingIntent != nil {
            startDrainIfNeeded()
        }
    }
}
