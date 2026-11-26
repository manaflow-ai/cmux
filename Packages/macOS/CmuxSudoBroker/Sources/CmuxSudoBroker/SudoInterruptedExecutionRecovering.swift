import Foundation

protocol SudoInterruptedExecutionRecovering: Sendable {
    func recover(
        states: [SudoRequestState],
        approvedDirectory: URL
    ) async -> [String: SudoExecutionRecoveryDisposition]
}
