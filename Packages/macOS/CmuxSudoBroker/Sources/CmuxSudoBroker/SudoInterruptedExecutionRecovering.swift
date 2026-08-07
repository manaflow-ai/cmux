import Foundation

protocol SudoInterruptedExecutionRecovering: Sendable {
    func recover(
        state: SudoRequestState,
        approvedDirectory: URL
    ) async -> SudoExecutionRecoveryDisposition
}
