import Darwin
import Foundation
import Testing

/// Samples this test process with `/usr/bin/sample` for the "not a check" profile tests
/// (`SpaceSwitchCostTests.profileOfASpaceSwitch`, `SidebarHugeGroupTests.profile10k`,
/// `SidebarScrollProfile`). Those tests run only with `CMUX_SAMPLE_PROFILE=1`, on a Mac where this
/// user may examine its own processes (Developer mode on, `DevToolsSecurity -enable`). Elsewhere
/// `sample` asks for an admin password to get the task port (`system.privilege.taskport`), and on a
/// CI runner nobody answers, so it never exits.
///
/// The wait for `sample` never blocks the main thread and is bounded. A deadline armed at launch
/// (`seconds + grace`) stops a `sample` that is still running (`Process.terminate`), even when the
/// test throws before `finish()`; `finish()` suspends until `sample` exits or the deadline plus
/// `stopGrace` passes, and records an issue with what `sample` printed to stderr. The deadline task
/// is cancelled once `sample` exits.
@MainActor
final class SelfSampler {
    /// Opt-in for the self-sampling profile tests, like the `*_BENCH` flags.
    nonisolated static let enabled = ProcessInfo.processInfo.environment["CMUX_SAMPLE_PROFILE"] == "1"

    /// Time `sample` gets after its sampling window to symbolicate and write its report.
    nonisolated static let grace: TimeInterval = 60
    /// Time a stopped `sample` gets to exit before `finish()` gives up on it.
    nonisolated static let stopGrace: TimeInterval = 10

    let seconds: Int
    let output: URL
    private let errors: URL
    private let process = Process()
    private let exited = SelfSamplerExit()
    private var deadline: Task<Void, Never>?
    private var stopped = false

    /// Starts sampling this process for `seconds`; the report goes to a temporary file named after `name`.
    init(name: String, seconds: Int) throws {
        self.seconds = seconds
        let directory = FileManager.default.temporaryDirectory
        output = directory.appendingPathComponent("\(name)-\(getpid()).sample.txt")
        errors = directory.appendingPathComponent("\(name)-\(getpid()).sample-stderr.txt")
        try? FileManager.default.removeItem(at: output)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), String(seconds), "1", "-mayDie", "-file", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errors)
        process.terminationHandler = { [exited] _ in exited.fire() }
        try process.run()
        let budget = TimeInterval(seconds) + Self.grace
        deadline = Task { @MainActor [self, exited] in
            guard (try? await Task.sleep(for: .seconds(budget))) != nil, process.isRunning else { return }
            stopped = true
            process.terminate()
            guard (try? await Task.sleep(for: .seconds(Self.stopGrace))) != nil else { return }
            exited.fire() // `sample` ignored SIGTERM: let `finish()` return anyway
        }
    }

    var isRunning: Bool { process.isRunning }

    /// Waits for `sample` to finish without blocking the main thread and returns its report, or nil
    /// (with a recorded issue) when it failed or had to be stopped at the deadline.
    func finish() async -> String? {
        await exited.wait()
        deadline?.cancel()
        let budget = TimeInterval(seconds) + Self.grace
        if stopped || process.isRunning {
            Issue.record("/usr/bin/sample did not exit within \(Int(budget)) s and was stopped; stderr: \(stderrText)")
            return nil
        }
        guard process.terminationStatus == 0 else {
            Issue.record("/usr/bin/sample exited with status \(process.terminationStatus); stderr: \(stderrText)")
            return nil
        }
        return try? String(contentsOf: output, encoding: .utf8)
    }

    private var stderrText: String {
        let text = (try? String(contentsOf: errors, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "(empty)" : String(text.prefix(2_000))
    }
}

/// Fires once `sample` exits, or once the deadline gave a stopped `sample` `stopGrace` to exit.
private final class SelfSamplerExit: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        lock.lock()
        fired = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
