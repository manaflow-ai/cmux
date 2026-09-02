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

    @concurrent
    func recover(
        states: [SudoRequestState],
        approvedDirectory: URL
    ) async -> [String: SudoExecutionRecoveryDisposition] {
        let recoverableStates = states.filter { state in
            guard let runner = state.runner else { return true }
            return !inspector.isRunning(runner)
        }
        let approvedScriptURLs = recoverableStates.map { state in
            approvedDirectory.appendingPathComponent("\(state.id).sh", isDirectory: false)
        }
        let identitiesByPath = inventory.identitiesByScriptPath(
            approvedScriptURLs: approvedScriptURLs
        )
        var dispositions: [String: SudoExecutionRecoveryDisposition] = [:]

        for state in states {
            if let runner = state.runner, inspector.isRunning(runner) {
                // A generation-safe live runner still owns the persisted deadline.
                dispositions[state.id] = .runnerActive
                continue
            }

            let approvedScriptPath = approvedDirectory
                .appendingPathComponent("\(state.id).sh", isDirectory: false)
                .standardizedFileURL.path
            var roots = identitiesByPath[approvedScriptPath] ?? []
            if let execution = state.execution,
               inspector.isRunning(execution),
               !roots.contains(execution) {
                roots.append(execution)
            }
            for survivor in state.cleanupSurvivors ?? []
            where inspector.isRunning(survivor) && !roots.contains(survivor) {
                roots.append(survivor)
            }

            let survivors = terminator.terminate(
                roots: roots.filter(inspector.isRunning)
            )
            dispositions[state.id] = survivors.isEmpty ? .recovered : .cleanupIncomplete
        }
        return dispositions
    }
}
