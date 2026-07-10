import Darwin
import CmuxFoundation
import Foundation
import os

struct SimulatorBoundedCommandResult: Sendable, Equatable {
    let standardOutput: Data
    let standardError: Data
    let outputWasTruncated: Bool
    let errorWasTruncated: Bool
    let exitStatus: Int32?
    let timedOut: Bool
    let executionError: String?
}

protocol SimulatorBoundedCommandRunning: Sendable {
    func runBounded(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?,
        standardOutputLimit: Int,
        standardErrorLimit: Int
    ) async -> SimulatorBoundedCommandResult
}

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
        timeout: TimeInterval?,
        standardOutputLimit: Int,
        standardErrorLimit: Int
    ) async -> SimulatorBoundedCommandResult {
        guard standardOutputLimit >= 0, standardErrorLimit >= 0 else {
            return SimulatorBoundedCommandResult(
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

        let executableURL: URL
        let processArguments: [String]
        if executable.hasPrefix("/") {
            executableURL = URL(fileURLWithPath: executable)
            processArguments = arguments
        } else {
            executableURL = URL(fileURLWithPath: "/usr/bin/env")
            processArguments = [executable] + arguments
        }

        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputDescriptor = standardOutput.fileHandleForReading.fileDescriptor
        let errorDescriptor = standardError.fileHandleForReading.fileDescriptor

        let cancellation = SimulatorBoundedCommandCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
            let state = OSAllocatedUnfairLock(initialState: RunState())

            @Sendable func recordAndCompleteIfReady(
                _ mutate: @Sendable (inout RunState) -> Void
            ) {
                let completion: (
                    SimulatorBoundedCommandResult?,
                    Task<Void, Never>?,
                    Task<Void, Never>?
                ) =
                    state.withLock { state in
                        mutate(&state)
                        let forceKillTask: Task<Void, Never>?
                        if state.didTerminate {
                            forceKillTask = state.forceKillTask
                            state.forceKillTask = nil
                        } else {
                            forceKillTask = nil
                        }
                        guard !state.resumed,
                              let output = state.standardOutput,
                              let error = state.standardError,
                              state.didTerminate else {
                            return (nil, nil, forceKillTask)
                        }
                        state.resumed = true
                        let deadlineTask = state.deadlineTask
                        state.deadlineTask = nil
                        return (
                            SimulatorBoundedCommandResult(
                                standardOutput: output.data,
                                standardError: error.data,
                                outputWasTruncated: output.truncated,
                                errorWasTruncated: error.truncated,
                                exitStatus: state.exitStatus,
                                timedOut: false,
                                executionError: nil
                            ),
                            deadlineTask,
                            forceKillTask
                        )
                    }
                completion.1?.cancel()
                completion.2?.cancel()
                if let result = completion.0 {
                    continuation.resume(returning: result)
                }
            }

            @Sendable func finishImmediately(_ result: SimulatorBoundedCommandResult) -> Bool {
                let completion: (Bool, Task<Void, Never>?) = state.withLock { state in
                    guard !state.resumed else { return (false, nil) }
                    state.resumed = true
                    let deadlineTask = state.deadlineTask
                    state.deadlineTask = nil
                    return (true, deadlineTask)
                }
                completion.1?.cancel()
                if completion.0 {
                    continuation.resume(returning: result)
                }
                return completion.0
            }

            @Sendable func scheduleForceKill(process: SimulatorProcessGroupProcess) {
                let sleeper = self.sleeper
                let grace = self.terminationGrace
                let task = Task.detached {
                    do {
                        // This bounded grace is the intended SIGTERM-to-SIGKILL deadline.
                        try await sleeper.sleep(for: grace)
                    } catch {
                        return
                    }
                    if process.isRunning { process.forceKill() }
                }
                let keepTask = state.withLock { state -> Bool in
                    guard !state.didTerminate,
                          state.process === process,
                          process.isRunning else { return false }
                    state.forceKillTask?.cancel()
                    state.forceKillTask = task
                    return true
                }
                if !keepTask { task.cancel() }
            }

            cancellation.install {
                let cancelled = SimulatorBoundedCommandResult(
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
                let process = state.withLock { $0.process }
                if finishImmediately(cancelled), let process, process.isRunning {
                    process.terminate()
                    scheduleForceKill(process: process)
                }
            }

            Task.detached {
                let output = Self.drain(outputDescriptor, limit: standardOutputLimit)
                recordAndCompleteIfReady { $0.standardOutput = output }
            }
            Task.detached {
                let error = Self.drain(errorDescriptor, limit: standardErrorLimit)
                recordAndCompleteIfReady { $0.standardError = error }
            }

            guard !cancellation.isCancelled else {
                try? standardOutput.fileHandleForWriting.close()
                try? standardError.fileHandleForWriting.close()
                return
            }
            beforeProcessRun?()

            do {
                let process = try SimulatorProcessGroupProcess.launch(
                    executableURL: executableURL,
                    arguments: processArguments,
                    currentDirectoryURL: URL(fileURLWithPath: directory),
                    standardOutputFD: standardOutput.fileHandleForWriting.fileDescriptor,
                    standardErrorFD: standardError.fileHandleForWriting.fileDescriptor,
                    fileDescriptorsToClose: [
                        standardOutput.fileHandleForReading.fileDescriptor,
                        standardOutput.fileHandleForWriting.fileDescriptor,
                        standardError.fileHandleForReading.fileDescriptor,
                        standardError.fileHandleForWriting.fileDescriptor,
                    ],
                    grouping: .dedicatedProcessGroup
                )
                state.withLock { $0.process = process }
                process.setTerminationHandler { status in
                    recordAndCompleteIfReady {
                        $0.didTerminate = true
                        $0.exitStatus = status
                    }
                }
                didRunProcess?(process.processIdentifier)

                if cancellation.isCancelled, process.isRunning {
                    process.terminate()
                    scheduleForceKill(process: process)
                }
            } catch {
                try? standardOutput.fileHandleForWriting.close()
                try? standardError.fileHandleForWriting.close()
                _ = finishImmediately(SimulatorBoundedCommandResult(
                    standardOutput: Data(),
                    standardError: Data(),
                    outputWasTruncated: false,
                    errorWasTruncated: false,
                    exitStatus: nil,
                    timedOut: false,
                    executionError: String(describing: error)
                ))
                return
            }

            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()

            guard let timeout else { return }
            let sleeper = self.sleeper
            let deadlineTask = Task {
                do {
                    // This bounded sleep is the intended simctl execution deadline.
                    try await sleeper.sleep(for: .seconds(max(0, timeout)))
                } catch {
                    return
                }
                let timedOut = SimulatorBoundedCommandResult(
                    standardOutput: Data(),
                    standardError: Data(),
                    outputWasTruncated: false,
                    errorWasTruncated: false,
                    exitStatus: nil,
                    timedOut: true,
                    executionError: nil
                )
                let process = state.withLock { $0.process }
                if finishImmediately(timedOut), let process, process.isRunning {
                    process.terminate()
                    scheduleForceKill(process: process)
                }
            }
            let alreadyFinished = state.withLock { state -> Bool in
                guard !state.resumed else { return true }
                state.deadlineTask = deadlineTask
                return false
            }
            if alreadyFinished {
                deadlineTask.cancel()
            }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private struct RunState {
        var standardOutput: CapturedStream?
        var standardError: CapturedStream?
        var didTerminate = false
        var exitStatus: Int32?
        var resumed = false
        var deadlineTask: Task<Void, Never>?
        var forceKillTask: Task<Void, Never>?
        var process: SimulatorProcessGroupProcess?
    }

    private struct CapturedStream: Sendable {
        let data: Data
        let truncated: Bool
    }

    private static func drain(_ fileDescriptor: Int32, limit: Int) -> CapturedStream {
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
        return CapturedStream(data: data, truncated: truncated)
    }

}

private final class SimulatorBoundedCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (@Sendable () -> Void)?

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(_ handler: @escaping @Sendable () -> Void) {
        let shouldRun = lock.withLock { () -> Bool in
            self.handler = handler
            return cancelled
        }
        if shouldRun { handler() }
    }

    func cancel() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !cancelled else { return nil }
            cancelled = true
            return self.handler
        }
        handler?()
    }
}

struct SimulatorLegacyBoundedCommandRunner: SimulatorBoundedCommandRunning, Sendable {
    let commands: any CommandRunning

    func runBounded(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?,
        standardOutputLimit: Int,
        standardErrorLimit: Int
    ) async -> SimulatorBoundedCommandResult {
        guard standardOutputLimit >= 0, standardErrorLimit >= 0 else {
            return SimulatorBoundedCommandResult(
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
        let result = await commands.run(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
        let output = Self.capture(result.stdout, limit: standardOutputLimit)
        let error = Self.capture(result.stderr, limit: standardErrorLimit)
        return SimulatorBoundedCommandResult(
            standardOutput: output.data,
            standardError: error.data,
            outputWasTruncated: output.truncated,
            errorWasTruncated: error.truncated,
            exitStatus: result.exitStatus,
            timedOut: result.timedOut,
            executionError: result.executionError
        )
    }

    private static func capture(_ string: String?, limit: Int) -> (data: Data, truncated: Bool) {
        let data = Data((string ?? "").utf8)
        return (Data(data.prefix(limit)), data.count > limit)
    }
}
