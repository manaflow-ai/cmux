import Foundation

struct SimulatorWorkerTerminationRecord {
    let reason: Process.TerminationReason
    let status: Int32
}
