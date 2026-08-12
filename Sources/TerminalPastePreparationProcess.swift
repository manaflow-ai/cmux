import Darwin
import Foundation

/// Owns one worker process from launch through reaping and cancellation.
actor TerminalPastePreparationProcess {
    private let process: Process
    private let livenessPipe: Pipe
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
        let livenessPipe = Pipe()
        process.standardInput = livenessPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.livenessPipe = livenessPipe
    }

    func run() async throws -> Int32 {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                // Install before launch: every successful launch, including an
                // immediate exit, completes through this handler. Launch
                // failures resume explicitly in the catch path below.
                process.terminationHandler = { [weak self] process in
                    let status = process.terminationStatus
                    Task {
                        await self?.processDidTerminate(status: status)
                    }
                }
                do {
                    try process.run()
                    try? livenessPipe.fileHandleForReading.close()
                    didStart = true
                    if Task.isCancelled {
                        kill()
                    }
                } catch {
                    closeLivenessPipe()
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
        closeLivenessPipe()
        continuation?.resume(returning: status)
        continuation = nil
    }

    private func closeLivenessPipe() {
        try? livenessPipe.fileHandleForReading.close()
        try? livenessPipe.fileHandleForWriting.close()
    }
}
