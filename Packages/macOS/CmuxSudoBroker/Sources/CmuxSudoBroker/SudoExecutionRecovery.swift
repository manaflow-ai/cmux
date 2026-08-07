import Foundation

struct SudoExecutionRecovery: SudoInterruptedExecutionRecovering {
    private let inspector: any SudoProcessInspecting
    private let inventory: SudoOrphanProcessInventory
    private let terminator: SudoProcessTreeTerminator

    init(
        inspector: any SudoProcessInspecting,
        signaler: any SudoProcessSignaling
    ) {
        self.inspector = inspector
        inventory = SudoOrphanProcessInventory(inspector: inspector)
        terminator = SudoProcessTreeTerminator(inspector: inspector, signaler: signaler)
    }

    func recover(
        state: SudoRequestState,
        approvedDirectory: URL
    ) async -> SudoExecutionRecoveryDisposition {
        if let runner = state.runner, inspector.isRunning(runner) {
            // A generation-safe live runner still owns the persisted deadline.
            return .runnerActive
        }

        let approvedScriptURL = approvedDirectory
            .appendingPathComponent("\(state.id).sh", isDirectory: false)
        var roots = inventory.identities(approvedScriptURL: approvedScriptURL)
        if let execution = state.execution,
           inspector.isRunning(execution),
           !roots.contains(execution) {
            roots.append(execution)
        }
        for survivor in state.cleanupSurvivors ?? []
        where inspector.isRunning(survivor) && !roots.contains(survivor) {
            roots.append(survivor)
        }

        var survivors: [SudoProcessIdentity] = []
        for root in roots where inspector.isRunning(root) {
            survivors.append(contentsOf: terminator.terminate(root: root))
        }
        return survivors.isEmpty ? .recovered : .cleanupIncomplete
    }
}
