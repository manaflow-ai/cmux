import Darwin
import Dispatch
import Foundation
import Testing

/// Samples this test process with `/usr/bin/sample` for the "not a check" profile tests
/// (`SpaceSwitchCostTests.profileOfASpaceSwitch`, `SidebarHugeGroupTests.profile10k`,
/// `SidebarScrollProfile`). Those tests run only with `CMUX_SAMPLE_PROFILE=1`, like the `*_BENCH`
/// flags: they print a profile and check nothing, they hold the main thread for tens of seconds,
/// and where this user may not examine its own processes (Developer mode off,
/// `system.privilege.taskport` asking for an admin) `sample` waits on a prompt nobody answers.
///
/// `run` never blocks the main thread on `sample` and always ends: `sample` is spawned and reaped
/// here (a process source on the main queue, so its pid stays ours until it is reaped), a
/// deadline armed at launch sends SIGTERM after `seconds + grace` and SIGKILL `stopGrace` later,
/// and a stop is reported with what `sample` printed to stderr. Temporary files are removed on
/// every path.
@MainActor
final class SelfSampler {
    /// Opt-in for the self-sampling profile tests.
    nonisolated static let enabled = ProcessInfo.processInfo.environment["CMUX_SAMPLE_PROFILE"] == "1"

    /// Time `sample` gets after its sampling window to symbolicate and write its report.
    nonisolated static let grace: TimeInterval = 60
    /// Time a signalled `sample` gets to exit before the next, harder step.
    nonisolated static let stopGrace: TimeInterval = 10

    /// Samples this process for `seconds` while `body` runs, then returns `sample`'s report (nil,
    /// with a recorded issue, when it failed or was stopped) and the body's value. If the body
    /// throws, `sample` is stopped at once and reaped, and the body's error is rethrown.
    static func run<T>(name: String, seconds: Int, _ body: @MainActor (SelfSampler) async throws -> T) async throws -> (report: String?, value: T) {
        let sampler = try SelfSampler(name: name, seconds: seconds)
        let result: Result<T, any Error>
        do { result = .success(try await body(sampler)) } catch { result = .failure(error) }
        if case .failure = result { sampler.stop() }
        let report = await sampler.finish(quiet: { if case .failure = result { true } else { false } }())
        return (report, try result.get())
    }

    /// Whether `sample` is still running (not yet reaped or given up on).
    var isRunning: Bool { status == nil && !gaveUp }

    let seconds: Int
    private let output: URL
    private let errors: URL
    private let pid: pid_t
    private var status: Int32?
    private var stopped = false
    private var gaveUp = false
    private var source: (any DispatchSourceProcess)?
    private var deadline: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init(name: String, seconds: Int) throws {
        self.seconds = seconds
        let run = "\(name)-\(getpid())-\(UUID().uuidString.prefix(8))"
        output = FileManager.default.temporaryDirectory.appendingPathComponent("\(run).sample.txt")
        errors = FileManager.default.temporaryDirectory.appendingPathComponent("\(run).sample-stderr.txt")
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, errors.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        let arguments = ["/usr/bin/sample", String(getpid()), String(seconds), "1", "-mayDie", "-file", output.path]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let spawned = posix_spawn(&child, "/usr/bin/sample", &actions, nil, argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        guard spawned == 0 else {
            try? FileManager.default.removeItem(at: errors)
            try? FileManager.default.removeItem(at: output)
            throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO)
        }
        pid = child
        // The child stays a zombie (its pid ours) until `reap` waits on it, and `reap`, the source
        // and the signals all run on the main actor, so a signal never reaches a reused pid.
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reap() } }
        source.resume()
        self.source = source
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.reap() } } // exited before the source was armed
        let budget = TimeInterval(seconds) + Self.grace
        deadline = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(budget))) != nil else { return }
            self?.stop()
        }
    }

    /// Reaps `sample` if it exited, and wakes `finish`.
    private func reap() {
        guard status == nil else { return }
        var raw: Int32 = 0
        guard waitpid(pid, &raw, WNOHANG) == pid else { return }
        status = raw
        source?.cancel()
        wake()
    }

    private func wake() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    /// SIGTERM now and SIGKILL `stopGrace` later; after another `stopGrace` `finish` returns even
    /// if the child was never reaped (its pid is never signalled again).
    private func stop() {
        guard status == nil, !stopped else { return }
        stopped = true
        kill(pid, SIGTERM)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.stopGrace))
            guard let self, status == nil else { return }
            kill(pid, SIGKILL)
            try? await Task.sleep(for: .seconds(Self.stopGrace))
            guard status == nil else { return }
            gaveUp = true
            wake()
        }
    }

    /// Waits, without blocking the main thread, until `sample` is reaped or given up on, removes the
    /// temporary files and returns the report. `quiet`: the caller already failed, record nothing.
    private func finish(quiet: Bool) async -> String? {
        if isRunning { await withCheckedContinuation { waiters.append($0) } }
        deadline?.cancel()
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: errors)
        }
        if quiet { return nil }
        guard let status, !stopped else {
            Issue.record("/usr/bin/sample did not exit within \(seconds + Int(Self.grace)) s and was stopped; stderr: \(stderrText)")
            return nil
        }
        guard status == 0 else {
            Issue.record("/usr/bin/sample exited with wait status \(status); stderr: \(stderrText)")
            return nil
        }
        guard let report = try? String(contentsOf: output, encoding: .utf8) else {
            Issue.record("/usr/bin/sample exited 0 but wrote no readable report at \(output.path); stderr: \(stderrText)")
            return nil
        }
        return report
    }

    private var stderrText: String {
        let text = (try? String(contentsOf: errors, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "(empty)" : String(text.prefix(2_000))
    }
}
