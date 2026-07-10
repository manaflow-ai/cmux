import Darwin
import Foundation
import CmuxSimulator

protocol SimulatorSubprocessSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

private struct ContinuousSimulatorSubprocessSleeper: SimulatorSubprocessSleeping {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

struct SimulatorSubprocessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
    let outputWasTruncated: Bool
    let errorWasTruncated: Bool
    let timedOut: Bool

    init(
        status: Int32,
        standardOutput: String,
        standardError: String,
        outputWasTruncated: Bool = false,
        errorWasTruncated: Bool = false,
        timedOut: Bool = false
    ) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputWasTruncated = outputWasTruncated
        self.errorWasTruncated = errorWasTruncated
        self.timedOut = timedOut
    }
}

struct SimulatorSubprocessRunner: Sendable {
    private let terminationGrace: Duration
    private let timeout: Duration
    private let standardOutputLimit: Int
    private let standardErrorLimit: Int
    private let sleeper: any SimulatorSubprocessSleeping

    init(
        terminationGrace: Duration = .seconds(1),
        timeout: Duration = .seconds(120),
        standardOutputLimit: Int = 8 * 1_024 * 1_024,
        standardErrorLimit: Int = 2 * 1_024 * 1_024,
        sleeper: any SimulatorSubprocessSleeping = ContinuousSimulatorSubprocessSleeper()
    ) {
        self.terminationGrace = terminationGrace
        self.timeout = timeout
        self.standardOutputLimit = standardOutputLimit
        self.standardErrorLimit = standardErrorLimit
        self.sleeper = sleeper
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) async throws -> SimulatorSubprocessResult {
        guard standardOutputLimit >= 0, standardErrorLimit >= 0 else {
            throw SimulatorWorkerFailure.privateAPIUnavailable(
                String(
                    localized: "simulator.failure.commandOutputLimit",
                    defaultValue: "Simulator subprocess output limits must be nonnegative."
                )
            )
        }
        let standardOutput = Pipe()
        let standardError = Pipe()
        let box = SimulatorSubprocessBox(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            standardOutput: standardOutput,
            standardError: standardError,
            terminationGrace: terminationGrace,
            timeout: timeout,
            standardOutputLimit: standardOutputLimit,
            standardErrorLimit: standardErrorLimit,
            sleeper: sleeper
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.start(continuation: continuation)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

private final class SimulatorSubprocessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let standardOutput: Pipe
    private let standardError: Pipe
    private let outputReader: SimulatorPipeReader
    private let errorReader: SimulatorPipeReader
    private let terminationGrace: Duration
    private let timeout: Duration
    private let sleeper: any SimulatorSubprocessSleeping
    private var finished = false
    private var cancellationRequested = false
    private var terminationSignalSent = false
    private var timedOut = false
    private var timeoutTask: Task<Void, Never>?
    private var forceKillTask: Task<Void, Never>?
    private var process: SimulatorProcessGroupProcess?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardOutput: Pipe,
        standardError: Pipe,
        terminationGrace: Duration,
        timeout: Duration,
        standardOutputLimit: Int,
        standardErrorLimit: Int,
        sleeper: any SimulatorSubprocessSleeping
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationGrace = terminationGrace
        self.timeout = timeout
        self.sleeper = sleeper
        outputReader = SimulatorPipeReader(
            handle: standardOutput.fileHandleForReading,
            name: "cmux-simulator-subprocess-stdout",
            limit: standardOutputLimit
        )
        errorReader = SimulatorPipeReader(
            handle: standardError.fileHandleForReading,
            name: "cmux-simulator-subprocess-stderr",
            limit: standardErrorLimit
        )
    }

    deinit {
        timeoutTask?.cancel()
        forceKillTask?.cancel()
        process?.forceKill()
    }

    func start(
        continuation: CheckedContinuation<SimulatorSubprocessResult, Error>
    ) {
        outputReader.start()
        errorReader.start()
        do {
            let process = try SimulatorProcessGroupProcess.launch(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                standardOutputFD: standardOutput.fileHandleForWriting.fileDescriptor,
                standardErrorFD: standardError.fileHandleForWriting.fileDescriptor,
                fileDescriptorsToClose: [
                    standardOutput.fileHandleForReading.fileDescriptor,
                    standardOutput.fileHandleForWriting.fileDescriptor,
                    standardError.fileHandleForReading.fileDescriptor,
                    standardError.fileHandleForWriting.fileDescriptor,
                ],
                grouping: .inheritedProcessGroup
            )
            lock.withLock { self.process = process }
            process.setTerminationHandler { [self] status in
                outputReader.requestStop()
                errorReader.requestStop()
                let output = outputReader.waitForEnd()
                let error = errorReader.waitForEnd()
                let completion = lock.withLock { () -> (
                    SimulatorSubprocessResult?,
                    Task<Void, Never>?,
                    Task<Void, Never>?
                ) in
                    guard !finished else { return (nil, nil, nil) }
                    finished = true
                    let pendingTimeoutTask = timeoutTask
                    let pendingForceKillTask = forceKillTask
                    timeoutTask = nil
                    forceKillTask = nil
                    return (
                        SimulatorSubprocessResult(
                            status: status,
                            standardOutput: String(decoding: output.data, as: UTF8.self),
                            standardError: String(decoding: error.data, as: UTF8.self),
                            outputWasTruncated: output.truncated,
                            errorWasTruncated: error.truncated,
                            timedOut: timedOut
                        ),
                        pendingTimeoutTask,
                        pendingForceKillTask
                    )
                }
                completion.1?.cancel()
                completion.2?.cancel()
                if let result = completion.0 {
                    continuation.resume(returning: result)
                }
            }
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            terminateIfCancellationWasRequested()
            scheduleTimeout()
        } catch {
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            let shouldResume = lock.withLock { () -> Bool in
                guard !finished else { return false }
                finished = true
                timeoutTask?.cancel()
                forceKillTask?.cancel()
                timeoutTask = nil
                forceKillTask = nil
                return true
            }
            if shouldResume { continuation.resume(throwing: error) }
        }
    }

    func cancel() {
        let process: SimulatorProcessGroupProcess? = lock.withLock {
            cancellationRequested = true
            return claimRunningProcessForTermination()
        }
        guard let process else { return }
        process.terminate()
        scheduleForceKill(process: process)
    }

    private func terminateIfCancellationWasRequested() {
        let process: SimulatorProcessGroupProcess? = lock.withLock {
            guard cancellationRequested else { return nil }
            return claimRunningProcessForTermination()
        }
        guard let process else { return }
        process.terminate()
        scheduleForceKill(process: process)
    }

    private func scheduleTimeout() {
        let timeout = self.timeout
        let sleeper = self.sleeper
        let task = Task.detached { [weak self] in
            do {
                // This bounded sleep is the subprocess execution deadline.
                try await sleeper.sleep(for: timeout)
            } catch {
                return
            }
            self?.deadlineExpired()
        }
        let keepTask = lock.withLock { () -> Bool in
            guard !finished else { return false }
            timeoutTask = task
            return true
        }
        if !keepTask { task.cancel() }
    }

    private func deadlineExpired() {
        let process: SimulatorProcessGroupProcess? = lock.withLock {
            guard !finished else { return nil }
            timedOut = true
            return claimRunningProcessForTermination()
        }
        guard let process else { return }
        process.terminate()
        scheduleForceKill(process: process)
    }

    private func claimRunningProcessForTermination() -> SimulatorProcessGroupProcess? {
        guard !terminationSignalSent, let process, process.isRunning else { return nil }
        terminationSignalSent = true
        return process
    }

    private func scheduleForceKill(process: SimulatorProcessGroupProcess) {
        let grace = terminationGrace
        let sleeper = self.sleeper
        let task = Task.detached { [weak self] in
            do {
                // This bounded grace is the intended SIGTERM-to-SIGKILL deadline.
                try await sleeper.sleep(for: grace)
            } catch {
                return
            }
            self?.forceKillIfRunning(process: process)
        }
        let keepTask = lock.withLock { () -> Bool in
            guard !finished,
                  self.process === process,
                  process.isRunning else { return false }
            forceKillTask?.cancel()
            forceKillTask = task
            return true
        }
        if !keepTask { task.cancel() }
    }

    private func forceKillIfRunning(process: SimulatorProcessGroupProcess) {
        lock.withLock {
            guard self.process === process, process.isRunning else { return }
            process.forceKill()
        }
    }
}

/// Drains a subprocess pipe concurrently so compiler diagnostics cannot fill
/// the kernel pipe buffer and deadlock the isolated worker.
private final class SimulatorPipeReader: @unchecked Sendable {
    private let condition = NSCondition()
    private let handle: FileHandle
    private let name: String
    private let limit: Int
    private var data = Data()
    private var truncated = false
    private var finished = false
    private var stopRequested = false

    init(handle: FileHandle, name: String, limit: Int) {
        self.handle = handle
        self.name = name
        self.limit = limit
    }

    func start() {
        let thread = Thread { [self] in
            let result = Self.readToEnd(
                fileDescriptor: handle.fileDescriptor,
                limit: limit,
                shouldStop: { self.shouldStop }
            )
            condition.lock()
            data = result.data
            truncated = result.truncated
            finished = true
            condition.broadcast()
            condition.unlock()
        }
        thread.name = name
        thread.stackSize = 1 << 20
        thread.start()
    }

    func requestStop() {
        condition.lock()
        stopRequested = true
        condition.unlock()
    }

    func waitForEnd() -> (data: Data, truncated: Bool) {
        condition.lock()
        defer { condition.unlock() }
        while !finished {
            condition.wait()
        }
        return (data, truncated)
    }

    private static func readToEnd(
        fileDescriptor: Int32,
        limit: Int,
        shouldStop: () -> Bool
    ) -> (data: Data, truncated: Bool) {
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
        var data = Data()
        data.reserveCapacity(limit)
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let bufferCount = buffer.count
            let count = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, bufferCount)
            }
            if count > 0 {
                let remaining = max(0, limit - data.count)
                if remaining > 0 {
                    data.append(contentsOf: buffer.prefix(min(count, remaining)))
                }
                if count > remaining { truncated = true }
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                if shouldStop() { break }
                var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 100)
            } else {
                break
            }
        }
        return (data, truncated)
    }


    private var shouldStop: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopRequested
    }
}
