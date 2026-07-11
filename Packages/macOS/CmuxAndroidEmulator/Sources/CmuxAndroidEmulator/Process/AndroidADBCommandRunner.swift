public import CmuxFoundation
import Darwin
import os
public import Foundation

/// Runs ADB with regular-file output so its persistent server cannot strand captured pipes.
public actor AndroidADBCommandRunner: CommandRunning {
    private let environment: [String: String]

    /// Creates a runner with the environment inherited by ADB processes.
    public init(environment: [String: String]) {
        self.environment = environment
    }

    /// Runs an ADB command and captures its bounded result.
    public func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-adb-\(UUID().uuidString).out")
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-adb-\(UUID().uuidString).err")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            return failure("Could not create ADB output files")
        }
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        do {
            let output = try FileHandle(forWritingTo: outputURL)
            let error = try FileHandle(forWritingTo: errorURL)
            defer {
                try? output.close()
                try? error.close()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = error
            return await withCheckedContinuation { continuation in
                let state = OSAllocatedUnfairLock(initialState: RunState())

                @Sendable func finish(_ result: CommandResult) -> Bool {
                    let (won, timer): (Bool, (any DispatchSourceTimer)?) = state.withLock { state in
                        guard !state.resumed else { return (false, nil) }
                        state.resumed = true
                        let timer = state.timer
                        state.timer = nil
                        return (true, timer)
                    }
                    timer?.cancel()
                    if won { continuation.resume(returning: result) }
                    return won
                }

                process.terminationHandler = { finished in
                    let result = CommandResult(
                        stdout: try? String(contentsOf: outputURL, encoding: .utf8),
                        stderr: try? String(contentsOf: errorURL, encoding: .utf8),
                        exitStatus: finished.terminationStatus,
                        timedOut: false,
                        executionError: nil
                    )
                    _ = finish(result)
                }

                do {
                    try process.run()
                } catch {
                    _ = finish(CommandResult(
                        stdout: nil,
                        stderr: nil,
                        exitStatus: nil,
                        timedOut: false,
                        executionError: String(describing: error)
                    ))
                    return
                }

                guard let timeout else { return }
                let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    let timedOut = CommandResult(
                        stdout: nil,
                        stderr: nil,
                        exitStatus: nil,
                        timedOut: true,
                        executionError: nil
                    )
                    if finish(timedOut), process.isRunning {
                        process.terminate()
                        kill(process.processIdentifier, SIGKILL)
                    }
                    timer.cancel()
                }
                let alreadyFinished = state.withLock { state in
                    if state.resumed { return true }
                    state.timer = timer
                    return false
                }
                if alreadyFinished {
                    timer.cancel()
                } else {
                    timer.resume()
                }
            }
        } catch {
            return failure(String(describing: error))
        }
    }

    private func failure(_ detail: String) -> CommandResult {
        CommandResult(
            stdout: nil,
            stderr: nil,
            exitStatus: nil,
            timedOut: false,
            executionError: detail
        )
    }

    private struct RunState {
        var resumed = false
        var timer: (any DispatchSourceTimer)?
    }

    private nonisolated static let timerQueue = DispatchQueue(
        label: "com.cmuxterm.CmuxAndroidEmulator.adb-timer"
    )
}
