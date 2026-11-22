import Darwin
import Foundation
import os
import Synchronization

nonisolated private let manifestLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")

/// Reads the capabilities a cmux Computer Use helper declares in
/// `cmux-cua manifest` (the top-level `capabilities` array), once per
/// helper binary (its path, modification date and size).
///
/// The wait is bounded by `timeout` on the injected clock and ends at once
/// when the caller is cancelled; the manifest process is then killed. A
/// manifest that fails, hangs or is not JSON declares nothing (an older
/// helper), is logged once, and is cached like a success. The manifest runs
/// with its own small environment; this process's environment is never
/// written (libghostty keeps a slice of `environ`).
nonisolated final class CuaHelperManifestReader: Sendable {
    /// `serve --owner-pid <pid>`: the helper exits and removes its socket when that pid exits.
    static let ownerPIDCapability = "serve.owner-pid"

    /// The app's reader. One cache per process.
    static let shared = CuaHelperManifestReader()

    private struct Key: Hashable {
        var path: String
        var modified: Date
        var size: Int
    }

    fileprivate enum Outcome: Sendable {
        case output(Data?)
        case timedOut
    }

    private let timeout: Duration
    private let clock: any Clock<Duration>
    private let cache = Mutex<[Key: Set<String>]>([:])

    init(timeout: Duration = .seconds(3), clock: any Clock<Duration> = ContinuousClock()) {
        self.timeout = timeout
        self.clock = clock
    }

    /// The capabilities of the helper app at `helper`; empty when it declares
    /// none or its manifest cannot be read.
    @concurrent func capabilities(of helper: URL) async -> Set<String> {
        let executable = Self.executable(of: helper)
        guard let key = Self.key(executable) else {
            manifestLogger.notice("cmux Computer Use helper manifest: no executable at \(executable.path, privacy: .public)")
            return []
        }
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let outcome = await Self.run(executable, timeout: timeout, clock: clock)
        // A cancelled read is not an answer about this binary: do not cache it.
        if Task.isCancelled { return [] }
        let capabilities: Set<String>
        switch outcome {
        case .timedOut:
            manifestLogger.notice("cmux Computer Use helper manifest timed out; starting without --owner-pid")
            capabilities = []
        case .output(let data):
            if let parsed = data.flatMap(Self.parse) {
                capabilities = parsed
            } else {
                manifestLogger.notice("cmux Computer Use helper manifest unreadable; starting without --owner-pid")
                capabilities = []
            }
        }
        cache.withLock { $0[key] = capabilities }
        return capabilities
    }

    /// The `capabilities` strings of a manifest; nil when it is not a JSON object.
    static func parse(_ data: Data) -> Set<String>? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Set((object["capabilities"] as? [Any] ?? []).compactMap { $0 as? String })
    }

    /// Called only from `capabilities(of:)`, which runs off the main actor.
    private static func executable(of helper: URL) -> URL {
        let plist = helper.appending(path: "Contents/Info.plist")
        // concurrency-allow: only called from @concurrent capabilities(of:), off the main actor; a small plist
        let info = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let name = info?["CFBundleExecutable"] as? String ?? "cmux-cua"
        return helper.appending(path: "Contents/MacOS/\(name)")
    }

    private static func key(_ executable: URL) -> Key? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        return Key(path: executable.path, modified: modified, size: size)
    }

    /// `<executable> manifest`'s standard output (nil when it does not
    /// start or exits nonzero), or `.timedOut` after `timeout` on `clock`.
    /// The bound and the caller's cancellation kill the process, so the
    /// wait always ends with it.
    private static func run(_ executable: URL, timeout: Duration, clock: any Clock<Duration>) async -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["manifest"]
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_CUA_TELEMETRY_ENABLED": "false",
            "CMUX_CUA_UPDATE_CHECK": "false",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let stop = ManifestStop()
        // task-owner: the bound of this one manifest run; cancelled when the run returns
        let deadline = Task {
            // wakeup-allow: one bounded deadline per helper binary; cancelled when the manifest answers
            do { try await clock.sleep(for: timeout) } catch { return }
            stop.stop(timedOut: true)
        }
        defer { deadline.cancel() }
        // The run returns at the first of: the manifest's output, the bound,
        // the caller's cancellation. A process that a stop killed may still
        // leave a grandchild holding its output; the reader then drains on
        // its own thread and its result is dropped.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                stop.begin(continuation)
                // task-owner: reads one manifest's output; ends at its EOF (the stop kills the process)
                Task.detached {
                    do { try process.run() } catch { return stop.finish(.output(nil)) }
                    stop.started(process.processIdentifier)
                    // concurrency-allow: a detached task off the main thread; EOF comes when the manifest exits or is killed
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    // concurrency-allow: same detached task; the process has closed its output
                    process.waitUntilExit()
                    stop.exited()
                    let succeeded = process.terminationReason == .exit && process.terminationStatus == 0
                    stop.finish(.output(succeeded ? data : nil))
                }
            }
        } onCancel: {
            stop.stop(timedOut: false)
        }
    }
}

/// Ends one manifest run once: with its output, or when its bound passes
/// or its caller cancels (the process is then killed, including a stop
/// that comes before the process has a pid).
nonisolated private final class ManifestStop: Sendable {
    typealias Outcome = CuaHelperManifestReader.Outcome

    private struct State {
        var pid: pid_t = 0
        var continuation: CheckedContinuation<Outcome, Never>?
        /// Set once; the run's answer, kept until `begin` when it comes first.
        var outcome: Outcome?
    }

    private let state = Mutex(State())

    func begin(_ continuation: CheckedContinuation<Outcome, Never>) {
        let early = state.withLock { state -> Outcome? in
            if let outcome = state.outcome { return outcome }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func started(_ pid: pid_t) {
        state.withLock { state in
            state.pid = pid
            if state.outcome != nil { kill(pid, SIGKILL) }
        }
    }

    /// The pid is cleared right after the exit, so a later kill cannot name another process.
    func exited() {
        state.withLock { $0.pid = 0 }
    }

    func finish(_ outcome: Outcome) {
        resolve(outcome, killing: false)
    }

    func stop(timedOut: Bool) {
        resolve(timedOut ? .timedOut : .output(nil), killing: true)
    }

    private func resolve(_ outcome: Outcome, killing: Bool) {
        let continuation = state.withLock { state -> CheckedContinuation<Outcome, Never>? in
            guard state.outcome == nil else { return nil }
            state.outcome = outcome
            if killing, state.pid > 0 { kill(state.pid, SIGKILL) }
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: outcome)
    }
}
