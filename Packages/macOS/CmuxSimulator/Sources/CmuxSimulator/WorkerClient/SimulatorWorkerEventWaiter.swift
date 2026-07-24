import Foundation

struct SimulatorWorkerEventWaiter {
    let identifier: UUID
    let continuation: CheckedContinuation<SimulatorWorkerEvent?, Never>
}
