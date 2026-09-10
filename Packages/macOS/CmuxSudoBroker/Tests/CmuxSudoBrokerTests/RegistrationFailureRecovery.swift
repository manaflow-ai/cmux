@testable import CmuxSudoBroker
import Foundation

actor RegistrationFailureRecovery: SudoInterruptedExecutionRecovering {
    let paths: SudoBrokerPaths
    let cleanupIncomplete: Bool
    private(set) var recoveredStates: [SudoRequestState] = []

    init(paths: SudoBrokerPaths, cleanupIncomplete: Bool) {
        self.paths = paths
        self.cleanupIncomplete = cleanupIncomplete
    }

    func recover(
        states: [SudoRequestState], approvedDirectory: URL
    ) async -> [String: SudoExecutionRecoveryDisposition] {
        recoveredStates += states
        for state in states {
            try? FileManager.default.removeItem(at: paths.locks.appendingPathComponent("\(state.id).lock"))
        }
        return Dictionary(uniqueKeysWithValues: states.map {
            ($0.id, cleanupIncomplete ? .cleanupIncomplete : .recovered)
        })
    }
}
