import Foundation

struct SimulatorUIAutomationTransactionWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
}
