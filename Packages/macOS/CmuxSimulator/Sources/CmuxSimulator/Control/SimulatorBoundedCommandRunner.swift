import Darwin
import Foundation

/// Captures subprocess output without allowing a chatty `simctl` command to
/// allocate memory proportional to its output. Both pipes continue draining
/// after their byte limits are reached so the child cannot block on a full pipe.
struct SimulatorBoundedCommandRunner: SimulatorBoundedCommandRunning, Sendable {
    private let terminationGrace: Duration
    private let sleeper: any SimulatorWorkerSleeping
    private let beforeProcessRun: (@Sendable () -> Void)?
    private let didRunProcess: (@Sendable (Int32) -> Void)?

    init(
        terminationGrace: Duration = .milliseconds(200),
        sleeper: any SimulatorWorkerSleeping = ContinuousSimulatorWorkerSleeper(),
        beforeProcessRun: (@Sendable () -> Void)? = nil,
        didRunProcess: (@Sendable (Int32) -> Void)? = nil
    ) {
        self.terminationGrace = terminationGrace
        self.sleeper = sleeper
        self.beforeProcessRun = beforeProcessRun
        self.didRunProcess = didRunProcess
    }

    func runBounded(
        directory: String,
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval?,
        standardOutputLimit: Int,
        standardErrorLimit: Int
    ) async -> SimulatorBoundedCommandResult {
        guard standardOutputLimit >= 0, standardErrorLimit >= 0 else {
            return invalidLimitResult
        }

        let executableURL: URL
        let processArguments: [String]
        if executable.hasPrefix("/") {
            executableURL = URL(fileURLWithPath: executable)
            processArguments = arguments
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/env")
            processArguments = [executable] + arguments
        }

        let cancellation = SimulatorBoundedCommandCancellationRelay()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let state = SimulatorBoundedCommandRunState(continuation: continuation)
                Task {
                    await cancellation.install(state)
                    if await cancellation.isCancelled {
                        if let process = await state.requestTermination(cancelledResult) {
                            await terminate(process, state: state)
                        }
                        return
                    }
                    await execute(
                        state: state,
                        executableURL: executableURL,
                        processArguments: processArguments,
                        environment: environment,
                        directory: directory,
                        timeout: timeout,
                        standardOutputLimit: standardOutputLimit,
                        standardErrorLimit: standardErrorLimit
                    )
                }
            }
        } onCancel: {
            Task {
                if let process = await cancellation.cancel(with: cancelledResult) {
                    await terminate(process, state: await cancellation.installedState)
                }
            }
        }
    }

    private func execute(
        state: SimulatorBoundedCommandRunState,
        executableURL: URL,
        processArguments: [String],
        environment: [String: String],
        directory: String,
        timeout: TimeInterval?,
        standardOutputLimit: Int,
        standardErrorLimit: Int
    ) async {
        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputReader = standardOutput.fileHandleForReading
        let errorReader = standardError.fileHandleForReading
        let outputFileDescriptor = outputReader.fileDescriptor
        let errorFileDescriptor = errorReader.fileDescriptor
        await state.installCaptureReaders([outputReader, errorReader])

        let outputDrainThread = Thread {
            let output = drain(outputFileDescriptor, limit: standardOutputLimit)
            try? outputReader.close()
            Task { await state.recordStandardOutput(output) }
        }
        outputDrainThread.name = "cmux-simulator-command-stdout"
        outputDrainThread.stackSize = 1 << 20
        outputDrainThread.start()

        let errorDrainThread = Thread {
            let error = drain(errorFileDescriptor, limit: standardErrorLimit)
            try? errorReader.close()
            Task { await state.recordStandardError(error) }
        }
        errorDrainThread.name = "cmux-simulator-command-stderr"
        errorDrainThread.stackSize = 1 << 20
        errorDrainThread.start()

        guard await state.beginLaunch() else {
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            return
        }
        beforeProcessRun?()

        let process: SimulatorProcessGroupProcess
        do {
            process = try SimulatorProcessGroupProcess(
                executableURL: executableURL,
                arguments: processArguments,
                environment: environment,
                currentDirectoryURL: URL(fileURLWithPath: directory),
                standardOutputFD: standardOutput.fileHandleForWriting.fileDescriptor,
                standardErrorFD: standardError.fileHandleForWriting.fileDescriptor,
                fileDescriptorsToClose: [
                    standardOutput.fileHandleForReading.fileDescriptor,
                    standardOutput.fileHandleForWriting.fileDescriptor,
                    standardError.fileHandleForReading.fileDescriptor,
                    standardError.fileHandleForWriting.fileDescriptor,
                ]
            )
        } catch {
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            await state.recordLaunchFailure(launchFailureResult(error))
            return
        }

        await process.setTerminationHandler { status in
            Task { await state.recordTermination(status) }
        }
        didRunProcess?(process.processIdentifier)
        let shouldTerminate = await state.install(process: process)

        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()

        if shouldTerminate {
            await terminate(process, state: state)
            return
        }
        guard let timeout else { return }
        let sleeper = sleeper
        let deadlineTask = Task {
            do {
                // This bounded sleep is the intended simctl execution deadline.
                try await sleeper.sleep(for: .seconds(max(0, timeout)))
            } catch {
                return
            }
            if let process = await state.requestTermination(timedOutResult) {
                await terminate(process, state: state)
            }
        }
        if !(await state.installDeadlineTask(deadlineTask)) {
            deadlineTask.cancel()
        }
    }

    private func terminate(
        _ process: SimulatorProcessGroupProcess,
        state: SimulatorBoundedCommandRunState?
    ) async {
        process.terminate()
        let sleeper = sleeper
        let grace = terminationGrace
        let task = Task.detached {
            do {
                // This bounded grace is the intended SIGTERM-to-SIGKILL deadline.
                try await sleeper.sleep(for: grace)
            } catch {
                return
            }
            if await process.isRunning { process.forceKill() }
            do {
                try await ContinuousSimulatorWorkerSleeper().sleep(for: .seconds(1))
            } catch { return }
            await state?.completeAfterTerminationDeadline()
        }
        guard let state, await state.installForceKillTask(task, for: process) else {
            task.cancel()
            return
        }
    }

    private func drain(_ fileDescriptor: Int32, limit: Int) -> SimulatorCapturedStream {
        var data = Data()
        data.reserveCapacity(limit)
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
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
            } else if errno != EINTR {
                break
            }
        }
        return SimulatorCapturedStream(data: data, truncated: truncated)
    }

    private var invalidLimitResult: SimulatorBoundedCommandResult {
        SimulatorBoundedCommandResult(
            standardOutput: Data(),
            standardError: Data(),
            outputWasTruncated: false,
            errorWasTruncated: false,
            exitStatus: nil,
            timedOut: false,
            executionError: String(
                localized: "simulator.failure.commandOutputLimit",
                defaultValue: "Simulator subprocess output limits must be nonnegative."
            )
        )
    }

    private var cancelledResult: SimulatorBoundedCommandResult {
        SimulatorBoundedCommandResult(
            standardOutput: Data(),
            standardError: Data(),
            outputWasTruncated: false,
            errorWasTruncated: false,
            exitStatus: nil,
            timedOut: false,
            executionError: String(
                localized: "simulator.failure.commandCancelled",
                defaultValue: "The Simulator command was cancelled."
            )
        )
    }

    private var timedOutResult: SimulatorBoundedCommandResult {
        SimulatorBoundedCommandResult(
            standardOutput: Data(),
            standardError: Data(),
            outputWasTruncated: false,
            errorWasTruncated: false,
            exitStatus: nil,
            timedOut: true,
            executionError: nil
        )
    }

    private func launchFailureResult(_ error: any Error) -> SimulatorBoundedCommandResult {
        SimulatorBoundedCommandResult(
            standardOutput: Data(),
            standardError: Data(),
            outputWasTruncated: false,
            errorWasTruncated: false,
            exitStatus: nil,
            timedOut: false,
            executionError: String(describing: error)
        )
    }
}
