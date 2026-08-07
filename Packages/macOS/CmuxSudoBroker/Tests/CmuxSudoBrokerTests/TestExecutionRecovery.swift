@testable import CmuxSudoBroker
import Foundation

actor TestExecutionRecovery: SudoInterruptedExecutionRecovering {
    private(set) var recoveredStates: [SudoRequestState] = []

    func recover(state: SudoRequestState, approvedDirectory: URL) async {
        recoveredStates.append(state)
    }
}

