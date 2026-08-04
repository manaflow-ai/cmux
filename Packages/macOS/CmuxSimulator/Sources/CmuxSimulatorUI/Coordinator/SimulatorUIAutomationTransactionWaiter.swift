import Foundation

struct SimulatorUIAutomationTransactionWaiter {
    let id: UUID
    let token: UUID
    let controlActionToken: UUID?
    let continuation: CheckedContinuation<Void, any Error>
}
