import Darwin
import Foundation

/// Owns one worker process from launch through reaping and cancellation.
actor TerminalPastePreparationProcess {
    private let process: Process
    private let livenessPipe: Pipe
    private let readinessPipe: Pipe?
    private let readinessSignal: (@Sendable () -> Void)?
    private var readinessSource: DispatchSourceRead?
    private var continuation: CheckedContinuation<Int32, Error>?
    private var didStart = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        readinessSignal: (@Sendable () -> Void)? = nil
    ) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        let livenessPipe = Pipe()
        process.standardInput = livenessPipe
        // A worker that reports startup writes one byte to stdout once its
        // own code runs, then redirects stdout away from this pipe.
        let readinessPipe = readinessSignal.map { _ in Pipe() }
        process.standardOutput = readinessPipe ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.livenessPipe = livenessPipe
        self.readinessPipe = readinessPipe
        self.readinessSignal = readinessSignal
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
                    startReadinessSource()
                    didStart = true
                    if Task.isCancelled {
                        kill()
                    }
                } catch {
                    closeLivenessPipe()
                    closeReadinessPipe()
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
        closeReadinessPipe()
        continuation?.resume(returning: status)
        continuation = nil
    }

    private func closeLivenessPipe() {
        try? livenessPipe.fileHandleForReading.close()
        try? livenessPipe.fileHandleForWriting.close()
    }

    /// Watches the worker's startup byte after launch. The source owns a
    /// duplicate of the read end, reads it with raw `read` (no NSFileHandle
    /// exceptions, see #4800), and closes it only from its cancel handler, so
    /// a read can never race the close.
    private func startReadinessSource() {
        guard let readinessPipe, let readinessSignal else { return }
        try? readinessPipe.fileHandleForWriting.close()
        let descriptor = fcntl(
            readinessPipe.fileHandleForReading.fileDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        try? readinessPipe.fileHandleForReading.close()
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { [weak source] in
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            source?.cancel()
            if count == 1 {
                readinessSignal()
            }
        }
        source.setCancelHandler {
            _ = Darwin.close(descriptor)
        }
        readinessSource = source
        source.resume()
    }

    private func closeReadinessPipe() {
        readinessSource?.cancel()
        readinessSource = nil
        try? readinessPipe?.fileHandleForReading.close()
        try? readinessPipe?.fileHandleForWriting.close()
    }
}
