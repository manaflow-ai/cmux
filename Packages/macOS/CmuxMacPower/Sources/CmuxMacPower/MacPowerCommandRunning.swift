internal import Foundation

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
/// `Sendable`; each call owns its own process and pipes, and runs the blocking
/// `Process` work on a background queue so the caller's actor is never blocked.
public struct SystemMacPowerCommandRunner: MacPowerCommandRunning {
    public init() {}

    @discardableResult
    public func run(_ tool: String, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.runSync(tool, arguments, captureOutput: false)
                continuation.resume(returning: result.success)
            }
        }
    }

    public func capture(_ tool: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.runSync(tool, arguments, captureOutput: true)
                continuation.resume(returning: result.success ? result.output : nil)
            }
        }
    }

    /// Launch `tool` synchronously, optionally capturing stdout. Reads the pipe
    /// to EOF before `waitUntilExit()` so a child that fills the pipe buffer
    /// cannot deadlock (the read drains it as the child writes).
    private static func runSync(
        _ tool: String,
        _ arguments: [String],
        captureOutput: Bool
    ) -> (success: Bool, output: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        if captureOutput {
            process.standardOutput = pipe
        } else {
            process.standardOutput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            return (false, nil)
        }

        var output: String?
        if captureOutput {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output = String(data: data, encoding: .utf8)
        }
        process.waitUntilExit()
        return (process.terminationStatus == 0, output)
    }
}
