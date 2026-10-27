import Darwin
import Foundation
import CmuxNextWakeups
import os
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// After an update: hand a running acpmux daemon of another build off to the
/// bundled build (plans/cmux-next/durable-sessions.md section 3), and one whose
/// executable was replaced with the app's bundle whatever its build
/// (``replaced(pid:)``). Only a daemon that runs its agents under agent hosts
/// (`_acpmux/status` `agentHosts`) is handed off: its SIGTERM detaches every
/// agent and the new daemon adopts them. An older daemon would end its agents,
/// so it keeps running until it exits on its own.
nonisolated enum AcpmuxVersionHandoff {
    enum Decision: Equatable, Sendable {
        case keep(String)
        case restart
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    /// Bundled builds this app process already handed off to: never twice.
    private static let handedOff = Mutex<Set<String>>([])

    /// `acpmux 0.1.0 (<build>)` -> `<build>`.
    static func build(fromVersion version: String) -> String? {
        guard let open = version.firstIndex(of: "("), let close = version.lastIndex(of: ")"), open < close else {
            return nil
        }
        let build = version[version.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return build.isEmpty ? nil : build
    }

    static func decide(_ running: String?, _ bundled: String?, _ agentHosts: Bool, replaced: Bool = false) -> Decision {
        if replaced { return agentHosts ? .restart : .keep("its agents would end: no agent hosts") }
        guard let running else { return .keep("running build unknown") }
        guard let bundled else { return .keep("bundled build unknown") }
        if running == bundled { return .keep("same build") }
        guard agentHosts else { return .keep("its agents would end: no agent hosts") }
        return .restart
    }

    /// Whether daemon `pid` runs an executable whose file is gone: the app's bundle was replaced
    /// in place after the daemon started (update-dev-daily.sh renames the old bundle aside and
    /// deletes it; a reinstall), so it is an earlier install of this app. The server peer check
    /// refuses it whatever its build, since its executable is not the bundled one, and every chat
    /// would say acpmux did not start (cx-ame2k). Another install's daemon (another
    /// copy of the same build, or an older build on `~/.acpmux`) runs a file that still exists.
    static func replaced(pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        guard let path = executablePath(pid: pid) else { return true }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// The executable path of process `pid` (`proc_pidpath`), nil when unknown.
    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        // SAFETY: proc_pidpath writes at most buffer.count bytes into the array's own storage, lent for the call.
        guard unsafe proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    #if DEBUG
    /// DEBUG only: whether `environment` runs the `CMUX_NEXT_ACPMUX_BIN` override and the daemon
    /// at `runningPath` is another binary (the bundled acpmux, or an earlier override). The server
    /// peer check refuses such a daemon whatever its build, so a swap restarts it like a replaced
    /// bundle would; comparing builds alone keeps it when both binaries come from one commit.
    static func swapsOverride(runningPath: String?, override: URL?, executable: URL) -> Bool {
        guard let override, override == executable, let runningPath else { return false }
        return URL(fileURLWithPath: runningPath).resolvingSymlinksInPath().path != executable.resolvingSymlinksInPath().path
    }
    #endif

    /// The bundled acpmux's build (`<executable> --version`).
    static func bundledBuild(_ environment: AcpmuxEnvironment) async -> String? {
        guard let outcome = try? await AsyncProcess().run(ProcessRequest(environment.executable, ["--version"])) else { return nil }
        return build(fromVersion: outcome.text)
    }

    /// Hands the daemon described by `status` off when it runs another build or
    /// a replaced bundle's executable, and keeps its agents across a restart.
    /// Returns true when it stopped that daemon, so the caller starts the
    /// bundled one.
    static func handOffIfStale(_ status: AcpmuxStatus, environment: AcpmuxEnvironment) async -> Bool {
        let bundled = await bundledBuild(environment)
        #if DEBUG
        let swapped = status.pid.map { swapsOverride(runningPath: executablePath(pid: $0),
                                                     override: AcpmuxEnvironment.debugExecutableOverride,
                                                     executable: environment.executable) } ?? false
        if swapped, let pid = status.pid {
            logger.info("acpmux \(pid) runs another binary than \(AcpmuxEnvironment.executableOverrideKey, privacy: .public) \(environment.executable.path, privacy: .public)")
        }
        let isReplaced = swapped || (status.pid.map(Self.replaced(pid:)) ?? false)
        #else
        let isReplaced = status.pid.map(Self.replaced(pid:)) ?? false
        #endif
        guard decide(status.build, bundled, status.agentHosts, replaced: isReplaced) == .restart, let pid = status.pid else {
            return false
        }
        guard handedOff.withLock({ $0.insert(bundled ?? "pid \(pid)").inserted }) else { return false }
        logger.info("acpmux \(pid) runs build \(status.build ?? "?", privacy: .public)\(isReplaced ? " from a replaced bundle" : "", privacy: .public); handing off to \(bundled ?? "?", privacy: .public)")
        do {
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath, home: environment.home)
        } catch {
            logger.error("acpmux handoff request failed: \(String(describing: error), privacy: .public)")
            return false
        }
        // The old daemon holds its lock until it exits; the new one needs it.
        return await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
    }
}

/// Waits for a process to exit through the kernel's exit event (no polling).
public nonisolated struct AgentPaneProcessExit: Sendable {
    public let pid: Int32
    /// The clock of the wait's deadline; tests pass a `ManualClock`.
    private let clock: any Clock<Duration>

    public init(pid: Int32, clock: any Clock<Duration> = ContinuousClock()) {
        self.pid = pid
        self.clock = clock
    }

    /// True at the exit; false when `timeout` passes first. A nil `timeout` waits for the exit only.
    public func event(within timeout: Duration?) async -> Bool {
        let pid = self.pid
        let clock = clock
        // Abandoned (the source and the deadline dropped without an answer) is not an exit.
        return (try? await withOnceContinuation { (continuation: OnceContinuation<Bool, OnceContinuationError>) in
            // The wait's bounded deadline (rare: one per handoff); cancelled at the exit event.
            let deadline = DemandTimer(owner: "agent-pane.process-exit", clock: clock)
            let queue = DispatchQueue(label: "cmux.next.agent-pane.acpmux-exit.\(pid)", qos: .userInitiated)
            // crash-allow: an immutable let; a dispatch source is a thread-safe libdispatch object (handlers, resume, cancel from any thread).
            nonisolated(unsafe) let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            // Every answer runs on `queue`, the source's own: the first cancels the source, and a later one
            // (a deadline or the gone-check queued before that) finds it cancelled.
            let finish: @Sendable (Bool) -> Void = { exited in
                guard !source.isCancelled else { return }
                source.cancel()
                deadline.cancel()
                continuation.resume(returning: exited)
            }
            if let timeout {
                deadline.schedule(after: timeout) { queue.async { finish(false) } }
            }
            source.setEventHandler { finish(true) }
            source.resume()
            // After the source is armed, so an exit between the two is still seen; a process that is already
            // gone gives no event.
            queue.async { if kill(pid, 0) != 0 && errno == ESRCH { finish(true) } }
        }) ?? false
    }
}
