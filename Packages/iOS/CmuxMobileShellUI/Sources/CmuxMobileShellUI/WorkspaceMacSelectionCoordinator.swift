import Observation

/// Owns the asynchronous coordination behind the workspace list's Mac picker.
///
/// SwiftUI keeps the coordinator reference alive for the list, while the
/// coordinator owns the mutable task, pending selection, and generation state.
/// Keeping those values here also makes the coordination deterministic for
/// callers that exercise a ``WorkspaceListView`` without mounting a view graph.
@MainActor
@Observable
final class WorkspaceMacSelectionCoordinator {
    typealias CancelMacSwitch = @MainActor (Bool) async -> Void

    @ObservationIgnored private var switchTask: Task<Void, Never>?
    @ObservationIgnored private var switchTaskGeneration: UInt64?
    @ObservationIgnored private var cancellationTask: Task<Void, Never>?
    @ObservationIgnored private var cancellationGeneration: UInt64?
    @ObservationIgnored private var switchGeneration: UInt64 = 0
    private(set) var pendingSelection: WorkspaceMacSelection?
    private(set) var deferredWorkspaceSelectionGeneration: UInt64 = 0

    var showsProgress: Bool {
        pendingSelection != nil
    }

    func invalidateDeferredWorkspaceSelection() {
        deferredWorkspaceSelectionGeneration &+= 1
    }

    func clearPendingSelection() {
        pendingSelection = nil
    }

    func isCurrentSwitchRequest(_ generation: UInt64?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let generation else { return true }
        return switchGeneration == generation
    }

    /// Starts the next machine switch after any prior cancellation has settled.
    @discardableResult
    func startSwitch(
        for selection: WorkspaceMacSelection,
        after cancellationTask: Task<Void, Never>?,
        apply: @escaping @MainActor (WorkspaceMacSelection, UInt64) async -> Void
    ) -> Task<Void, Never> {
        switchGeneration &+= 1
        let generation = switchGeneration
        pendingSelection = selection
        let task = Task { @MainActor in
            defer { finishSwitch(generation: generation) }
            await cancellationTask?.value
            guard isCurrentSwitchRequest(generation) else { return }
            await apply(selection, generation)
        }
        switchTask = task
        switchTaskGeneration = generation
        return task
    }

    @discardableResult
    func cancelPendingSwitch(
        restorePreviousOnCancel: Bool,
        cancelStoreSwitch: Bool,
        cancelMacSwitch: CancelMacSwitch?
    ) -> Task<Void, Never>? {
        let pendingSwitchTask = switchTask
        let pendingSwitchGeneration = switchTaskGeneration
        if pendingSwitchGeneration != cancellationGeneration {
            pendingSwitchTask?.cancel()
        }

        switchTask = nil
        switchTaskGeneration = nil
        pendingSelection = nil
        switchGeneration &+= 1
        let generation = switchGeneration
        if let cancellationTask {
            return cancellationTask
        }
        guard pendingSwitchTask != nil, cancelStoreSwitch else { return nil }

        let task = Task { @MainActor in
            defer { finishCancellation(generation: generation) }
            await cancelMacSwitch?(restorePreviousOnCancel)
        }
        cancellationTask = task
        cancellationGeneration = generation
        switchTask = task
        switchTaskGeneration = generation
        return task
    }

    private func finishSwitch(generation: UInt64) {
        guard switchTaskGeneration == generation else { return }
        switchTask = nil
        switchTaskGeneration = nil
    }

    private func finishCancellation(generation: UInt64) {
        guard cancellationGeneration == generation else { return }
        cancellationTask = nil
        cancellationGeneration = nil
        finishSwitch(generation: generation)
    }
}
