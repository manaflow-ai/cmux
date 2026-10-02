import Foundation

struct SimulatorBoundedCommandResult: Sendable, Equatable {
    let standardOutput: Data
    let standardError: Data
    let outputWasTruncated: Bool
    let errorWasTruncated: Bool
    let exitStatus: Int32?
    let timedOut: Bool
    let executionError: String?
}
