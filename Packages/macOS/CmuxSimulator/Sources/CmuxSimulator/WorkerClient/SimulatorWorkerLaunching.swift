import Foundation

protocol SimulatorWorkerLaunching: Sendable {
    func launch(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> SimulatorWorkerConnection
}
