@testable import CmuxSudoBroker
import Foundation

actor TestExecutionRecovery: SudoInterruptedExecutionRecovering {
    private(set) var recoveredStates: [SudoRequestState] = []
    private let disposition: SudoExecutionRecoveryDisposition

    init(disposition: SudoExecutionRecoveryDisposition = .recovered) {
        self.disposition = disposition
    }

    func recover(
        state: SudoRequestState,
        approvedDirectory: URL
    ) async -> SudoExecutionRecoveryDisposition {
        recoveredStates.append(state)
        return disposition
    }
}
