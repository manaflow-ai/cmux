import Darwin
import Foundation

/// Owns one worker process from launch through reaping and cancellation.
actor TerminalPastePreparationProcess {
    private let process: Process
    private var continuation: CheckedContinuation<Int32, Error>?
    private var didStart = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.process = process
    }

    func run() async throws -> Int32 {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                process.terminationHandler = { [weak self] process in
                    let status = process.terminationStatus
                    Task {
                        await self?.processDidTerminate(status: status)
                    }
                }
                do {
                    try process.run()
                    didStart = true
                    if Task.isCancelled {
                        kill()
                    }
                } catch {
                    self.continuation = nil
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task {
                await self.kill()
            }
        }
    }

    private func kill() {
        guard didStart, process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }

    private func processDidTerminate(status: Int32) {
        didStart = false
        process.terminationHandler = nil
        continuation?.resume(returning: status)
        continuation = nil
    }
}
