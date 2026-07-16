import CmuxSimulator
import Foundation

actor SimulatorSubprocessBox {
    static let supervisorScript = #"""
    exec 3<&0
    (IFS= read -r _ <&3 || kill -KILL 0) &
    watchdog=$!
    exec 3<&-
    "$@" </dev/null
    status=$?
    kill -KILL "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    exit "$status"
    """#

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let standardOutput: Pipe
    private let standardError: Pipe
    private let parentLifetime = Pipe()
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
    ) async {
        await outputReader.start()
        await errorReader.start()
        do {
            let process = try SimulatorProcessGroupProcess(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    Self.supervisorScript,
                    "cmux-simulator-command-supervisor",
                    executableURL.path,
                ] + arguments,
                environment: environment,
                standardInputFD: parentLifetime.fileHandleForReading.fileDescriptor,
                standardOutputFD: standardOutput.fileHandleForWriting.fileDescriptor,
                standardErrorFD: standardError.fileHandleForWriting.fileDescriptor,
                fileDescriptorsToClose: [
                    parentLifetime.fileHandleForReading.fileDescriptor,
                    parentLifetime.fileHandleForWriting.fileDescriptor,
                    standardOutput.fileHandleForReading.fileDescriptor,
                    standardOutput.fileHandleForWriting.fileDescriptor,
                    standardError.fileHandleForReading.fileDescriptor,
                    standardError.fileHandleForWriting.fileDescriptor,
                ]
            )
            self.process = process
            await process.setTerminationHandler { [self] status in
                Task { await finish(status: status, continuation: continuation) }
            }
            try? parentLifetime.fileHandleForReading.close()
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            terminateIfCancellationWasRequested()
            scheduleTimeout()
        } catch {
            try? parentLifetime.fileHandleForReading.close()
            try? parentLifetime.fileHandleForWriting.close()
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            await outputReader.requestStop()
            await errorReader.requestStop()
            _ = await outputReader.waitForEnd()
            _ = await errorReader.waitForEnd()
            guard !finished else { return }
            finished = true
            timeoutTask?.cancel()
            forceKillTask?.cancel()
            timeoutTask = nil
            forceKillTask = nil
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        cancellationRequested = true
        guard let process = claimRunningProcessForTermination() else { return }
        process.terminate()
        scheduleForceKill(process: process)
    }

    private func finish(
        status: Int32,
        continuation: CheckedContinuation<SimulatorSubprocessResult, Error>
    ) async {
        try? parentLifetime.fileHandleForWriting.close()
        await outputReader.requestStop()
        await errorReader.requestStop()
        let output = await outputReader.waitForEnd()
        let error = await errorReader.waitForEnd()
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        forceKillTask?.cancel()
        timeoutTask = nil
        forceKillTask = nil
        continuation.resume(returning: SimulatorSubprocessResult(
            status: status,
            standardOutput: String(decoding: output.data, as: UTF8.self),
            standardError: String(decoding: error.data, as: UTF8.self),
            outputWasTruncated: output.truncated,
            errorWasTruncated: error.truncated,
            timedOut: timedOut
        ))
    }

    private func terminateIfCancellationWasRequested() {
        guard cancellationRequested,
              let process = claimRunningProcessForTermination() else { return }
        process.terminate()
        scheduleForceKill(process: process)
    }

    private func scheduleTimeout() {
        let timeout = self.timeout
        let sleeper = self.sleeper
        let task = Task.detached { [weak self] in
            do {
                try await sleeper.sleep(for: timeout)
            } catch {
                return
            }
            await self?.deadlineExpired()
        }
        guard !finished else {
            task.cancel()
            return
        }
        timeoutTask = task
    }

    private func deadlineExpired() {
        guard !finished else { return }
        timedOut = true
        guard let process = claimRunningProcessForTermination() else { return }
        process.terminate()
        scheduleForceKill(process: process)
    }

    private func claimRunningProcessForTermination() -> SimulatorProcessGroupProcess? {
        guard !finished, !terminationSignalSent, let process else { return nil }
        terminationSignalSent = true
        return process
    }

    private func scheduleForceKill(process: SimulatorProcessGroupProcess) {
        let grace = terminationGrace
        let sleeper = self.sleeper
        let task = Task.detached { [weak self] in
            do {
                try await sleeper.sleep(for: grace)
            } catch {
                return
            }
            await self?.forceKillIfRunning(process: process)
        }
        guard !finished, self.process === process else {
            task.cancel()
            return
        }
        forceKillTask?.cancel()
        forceKillTask = task
    }

    private func forceKillIfRunning(process: SimulatorProcessGroupProcess) {
        guard !finished, self.process === process else { return }
        process.forceKill()
    }
}
