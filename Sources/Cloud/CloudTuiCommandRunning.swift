import Foundation

/// The one machine-link operation the attachment resolver depends on: run a
/// cmux-tui CLI command against the link socket under a bounded deadline.
///
/// ``CloudMachineLink`` is the production implementation. Tests conform a
/// scripted runner that answers per argv, so resolver behavior is observable
/// without a client process or a machine.
protocol CloudTuiCommandRunning: Sendable {
    /// Runs one command and returns its stdout. Throws
    /// ``CloudMachineLink/LinkError`` for a non-zero exit, a spawn failure, or
    /// the deadline.
    func runTuiCommand(arguments: [String], deadline: Duration) async throws -> Data
}

extension CloudMachineLink: CloudTuiCommandRunning {
    func runTuiCommand(arguments: [String], deadline: Duration) async throws -> Data {
        try await run(arguments: arguments, input: nil, timeout: deadline)
    }
}
