@testable import CmuxSudoBroker
import Foundation

actor TestExecutionRecovery: SudoInterruptedExecutionRecovering {
    private(set) var recoveredStates: [SudoRequestState] = []
    private(set) var recoveryBatches: [[SudoRequestState]] = []
    private let disposition: SudoExecutionRecoveryDisposition

    init(disposition: SudoExecutionRecoveryDisposition = .recovered) {
        self.disposition = disposition
    }

    func recover(
        states: [SudoRequestState],
        approvedDirectory: URL
    ) async -> [String: SudoExecutionRecoveryDisposition] {
        recoveryBatches.append(states)
        recoveredStates.append(contentsOf: states)
        return Dictionary(
            uniqueKeysWithValues: states.map { ($0.id, disposition) }
        )
    }
}
