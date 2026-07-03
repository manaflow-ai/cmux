import Darwin
internal import Foundation
import os

/// Seam for the system commands the Mac power controller runs, so tests can
/// inject a fake instead of mutating the real machine. Async so callers never
/// block a thread on a slow command (or the loginwindow round-trip an
/// AppleScript sleep can take).
public protocol MacPowerCommandRunning: Sendable {
    /// Run a tool and report whether it exited cleanly (status 0). Used for
    /// fire-and-forget effects such as `osascript … to sleep` or
    /// `pkill -x caffeinate`.
    @discardableResult
    func run(_ tool: String, _ arguments: [String]) async -> Bool

    /// Run a tool and capture its stdout, or `nil` if it failed to launch. Used
    /// for read-only probes such as `pmset -g assertions`.
    func capture(_ tool: String, _ arguments: [String]) async -> String?
}

/// Production runner backed by `Process`. The struct is stateless and
/// `Sendable`; each call owns its own process and pipes, drains stdout off the
/// caller's actor, and applies a deadline so wedged system tools do not hang a
/// mobile RPC indefinitely.
public struct SystemMacPowerCommandRunner: MacPowerCommandRunning {
    /// Seconds to wait after `SIGTERM` before forcing a timed-out command down.
    private static let sigkillGraceSeconds: Double = 0.2

    // Hosts one-shot process deadline timers. This queue delivers timer events
    // only; shared completion state is guarded by the per-call lock below.
    private static let timerQueue = DispatchQueue(label: "dev.cmux.mac-power-command-runner.timer")

    private let timeout: TimeInterval?

    /// Creates a system command runner.
    /// - Parameter timeout: Per-command deadline in seconds. Pass `nil` only for
    ///   tests that intentionally need to observe an unbounded command.
    public init(timeout: TimeInterval? = 10) {
        self.timeout = timeout
    }

    @discardableResult
    public func run(_ tool: String, _ arguments: [String]) async -> Bool {
        await Self.runProcess(tool, arguments, captureOutput: false, timeout: timeout).success
    }

    public func capture(_ tool: String, _ arguments: [String]) async -> String? {
        let result = await Self.runProcess(tool, arguments, captureOutput: true, timeout: timeout)
        return result.success ? result.output : nil
    }

    private struct RunResult {
        let success: Bool
        let output: String?
    }

    /// Mutable state shared across the stdout reader, termination handler,
    /// deadline timer, and spawn-failure path while one process resolves.
    private struct RunState {
        var output: Data?
        var didTerminate = false
        var exitStatus: Int32?
        var resumed = false
        var deadlineTimer: (any DispatchSourceTimer)?
    }

    /// Launch `tool`, optionally capturing stdout. The stdout reader starts
    /// before spawn so a child cannot deadlock against a full pipe; the deadline
    /// is cancelled only when this helper returns a terminal result.
    private static func runProcess(
        _ tool: String,
        _ arguments: [String],
        captureOutput: Bool,
        timeout: TimeInterval?
    ) async -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let pipe: Pipe?
        if captureOutput {
            let outputPipe = Pipe()
            pipe = outputPipe
            process.standardOutput = outputPipe
        } else {
            pipe = nil
            process.standardOutput = FileHandle.nullDevice
        }

        return await withCheckedContinuation { continuation in
            // The stdout reader, termination handler, timer, and spawn-failure
            // path are synchronous callbacks racing to finish one process. A
            // small lock is the narrow synchronous coordination carve-out; using
            // an actor here would only add Task hops around callback state.
            let state = OSAllocatedUnfairLock(initialState: RunState(output: captureOutput ? nil : Data()))

            @Sendable func recordAndCompleteIfReady(_ mutate: @Sendable (inout RunState) -> Void) {
                let (completed, timerToCancel): (RunResult?, (any DispatchSourceTimer)?) =
                    state.withLock { current in
                        mutate(&current)
                        guard !current.resumed,
                              let output = current.output,
                              current.didTerminate else {
                            return (nil, nil)
                        }
                        current.resumed = true
                        let timer = current.deadlineTimer
                        current.deadlineTimer = nil
                        return (
                            RunResult(
                                success: current.exitStatus == 0,
                                output: String(data: output, encoding: .utf8)
                            ),
                            timer
                        )
                    }
                timerToCancel?.cancel()
                if let completed {
                    continuation.resume(returning: completed)
                }
            }

            @Sendable func claimImmediate(_ result: RunResult) -> Bool {
                let (won, timerToCancel): (Bool, (any DispatchSourceTimer)?) =
                    state.withLock { current in
                        if current.resumed { return (false, nil) }
                        current.resumed = true
                        let timer = current.deadlineTimer
                        current.deadlineTimer = nil
                        return (true, timer)
                    }
                timerToCancel?.cancel()
                if won {
                    continuation.resume(returning: result)
                }
                return won
            }

            if let pipe {
                let outputDescriptor = pipe.fileHandleForReading.fileDescriptor
                Task.detached {
                    let data = Self.readToEnd(fileDescriptor: outputDescriptor)
                    recordAndCompleteIfReady { $0.output = data }
                }
            }

            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                recordAndCompleteIfReady {
                    $0.didTerminate = true
                    $0.exitStatus = status
                }
            }

            do {
                try process.run()
            } catch {
                try? pipe?.fileHandleForWriting.close()
                _ = claimImmediate(RunResult(success: false, output: nil))
                return
            }

            try? pipe?.fileHandleForWriting.close()

            guard let timeout else { return }
            // Genuine process deadline outside an async context: a one-shot
            // DispatchSource timer bounds tools that stall behind OS prompts.
            let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
            timer.schedule(deadline: .now() + max(timeout, 0))
            timer.setEventHandler {
                if claimImmediate(RunResult(success: false, output: nil)), process.isRunning {
                    process.terminate()
                    Self.scheduleSigkill(process)
                }
                timer.cancel()
            }
            let alreadyCompleted = state.withLock { current -> Bool in
                if current.resumed { return true }
                current.deadlineTimer = timer
                return false
            }
            if alreadyCompleted {
                timer.cancel()
            } else {
                timer.resume()
            }
        }
    }

    private static func scheduleSigkill(_ process: Process) {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + sigkillGraceSeconds)
        timer.setEventHandler {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            timer.cancel()
        }
        timer.resume()
    }

    private static func readToEnd(fileDescriptor: Int32) -> Data {
        var data = Data()
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, chunkSize)
            }
            if bytesRead > 0 {
                data.append(contentsOf: buffer[0..<bytesRead])
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data
    }
}
