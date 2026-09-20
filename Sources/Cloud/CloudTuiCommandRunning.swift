import Foundation

enum CloudTuiSendError: Error {
    case notSent(Error)
    case ambiguous(Error)
}

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
    func runTuiCommand(arguments: CloudTuiRequest, deadline: Duration) async throws -> Data
}

/// Sends a Cloud TUI request without waiting for its response.
///
/// Input uses this path because the PTY is the source of truth for echo and
/// line discipline. The request is written on the link's persistent channel;
/// no retry is attempted after the bytes have been handed to that channel.
protocol CloudTuiUntrackedCommandSending: Sendable {
    func sendUntrackedTuiCommand(arguments: CloudTuiRequest) async throws
    func sendTuiCommandAndAwaitAck(arguments: CloudTuiRequest) async throws
}

extension CloudMachineLink: CloudTuiCommandRunning {
    func runTuiCommand(arguments: CloudTuiRequest, deadline: Duration) async throws -> Data {
        try await run(arguments: arguments, timeout: deadline)
    }
}

extension CloudMachineLink: CloudTuiUntrackedCommandSending {
    func sendTuiCommandAndAwaitAck(arguments: CloudTuiRequest) async throws {
        _ = try await run(arguments: arguments, timeout: .seconds(30))
    }
}
