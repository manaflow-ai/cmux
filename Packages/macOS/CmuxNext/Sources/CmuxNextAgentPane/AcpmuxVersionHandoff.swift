import Darwin
import Foundation
import os
import CmuxNextCompat

/// After an update: hand a running acpmux daemon of another build off to the
/// bundled build (plans/cmux-next/durable-sessions.md section 3), and one whose
/// executable was replaced with the app's bundle whatever its build
/// (``replaced(pid:)``). A daemon that runs its agents under agent hosts
/// (`_acpmux/status` `agentHosts`) detaches every agent at its SIGTERM and the new
/// daemon adopts them. A daemon without agent hosts ends its agents when it stops, but
/// each chat's session, log and resume id stay on disk and its next prompt resumes it.
/// Either way a running turn or a waiting permission could be cut, so with the
/// `agent.replaceStaleAcpmuxWhenQuiet` Debug Settings toggle (on by default) the handoff
/// waits for a moment when no session has either (``AcpmuxQuietHandoff``). A daemon with
/// agent hosts waits no longer than ``AcpmuxQuietHandoff/cap``, nor at all when it runs a
/// replaced bundle (no chat can use it). Off, as before: one with agent hosts is handed
/// off at once, one without keeps running until it exits on its own. Never `endAgents`.
nonisolated enum AcpmuxVersionHandoff {
    enum Decision: Equatable, Sendable {
        case keep(String)
        case restart
        /// Restart it once its sessions are quiet: ask them first.
        case restartWhenQuiet
    }

    /// What ``handOffIfStale(_:environment:quietWait:)`` did.
    enum Outcome: Equatable, Sendable {
        /// It keeps running: the same build, or a restart would lose what it runs.
        case kept
        /// It is stale but busy: it is handed off at a quiet moment (``AcpmuxQuietHandoff``).
        case waitingForQuiet
        /// It stopped: start the bundled daemon.
        case stopped
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    /// Bundled builds this app process already handed off to: never twice.
    private static let handedOff = Mutex<Set<String>>([])
    /// The bundled acpmux's build by its file's identity (path, inode, size, mtime): asked once
    /// per file, and again after an update replaced it.
    private static let bundledBuilds = Mutex<[String: String]>([:])

    /// `acpmux 0.1.0 (<build>)` -> `<build>`.
    static func build(fromVersion version: String) -> String? {
        guard let open = version.firstIndex(of: "("), let close = version.lastIndex(of: ")"), open < close else {
            return nil
        }
        let build = version[version.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return build.isEmpty ? nil : build
    }

    /// - Parameters:
    ///   - whenQuiet: hand off at a quiet moment, also a daemon without agent hosts.
    ///   - quiet: whether its sessions are quiet (``AcpmuxQuietHandoff/quiet(sessions:)``); nil when not asked yet.
    ///   - overdue: it has agent hosts and waited for quiet past the cap.
    static func decide(_ running: String?, _ bundled: String?, _ agentHosts: Bool, replaced: Bool = false,
                       whenQuiet: Bool = false, quiet: Bool? = nil, overdue: Bool = false) -> Decision {
        if !replaced {
            guard let running else { return .keep("running build unknown") }
            guard let bundled else { return .keep("bundled build unknown") }
            if running == bundled { return .keep("same build") }
        }
        guard whenQuiet else { return agentHosts ? .restart : .keep("its agents would end: no agent hosts") }
        if agentHosts && (replaced || overdue) { return .restart }
        guard let quiet else { return .restartWhenQuiet }
        return quiet ? .restart : .keep("a turn runs or a permission waits")
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
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
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

    /// The bundled acpmux's build (`<executable> --version`), asked again once its file changed.
    static func bundledBuild(_ environment: AcpmuxEnvironment) async -> String? {
        let stamp = fileStamp(environment.executable)
        if let stamp, let known = bundledBuilds.withLock({ $0[stamp] }) { return known }
        let asked = await Task.detached { () -> String? in
            let process = Process()
            process.executableURL = environment.executable
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            // concurrency-allow: a detached task off the main thread; `--version` prints one line and exits
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // concurrency-allow: same detached task; the process has closed its output
            process.waitUntilExit()
            return Self.build(fromVersion: String(decoding: data, as: UTF8.self))
        }.value
        if let stamp, let asked { bundledBuilds.withLock { $0[stamp] = asked } }
        return asked
    }

    /// The identity of the file at `url` (symlinks resolved): its path, inode, size and modification time.
    static func fileStamp(_ url: URL) -> String? {
        let path = url.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(inode)|\(size)|\(modified)"
    }

    /// Hands the daemon described by `status` off when it runs another build or a replaced
    /// bundle's executable; its agent hosts keep its agents across the restart. With
    /// `quietWait` (the toggle on) it waits for a quiet moment as the type says: a busy daemon
    /// is kept, `quietWait` notes since when, and that does not use up this build's handoff.
    @concurrent static func handOffIfStale(_ status: AcpmuxStatus, environment: AcpmuxEnvironment,
                                           quietWait: AcpmuxQuietHandoff? = nil) async -> Outcome {
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
        guard let pid = status.pid else { return .kept }
        let key = bundled ?? "pid \(pid)"
        let home = environment.home.standardizedFileURL.path
        // A memory store keeps no session on disk to resume from: never without agent hosts.
        let whenQuiet = quietWait != nil && !status.memoryStore
        let overdue = quietWait?.overdue(home: home, pid: pid) ?? false
        var decision = decide(status.build, bundled, status.agentHosts, replaced: isReplaced,
                              whenQuiet: whenQuiet, overdue: overdue)
        if decision == .restartWhenQuiet {
            // A busy daemon does not use up this build's handoff.
            guard !handedOff.withLock({ $0.contains(key) }) else { return .kept }
            let quiet = await AcpmuxQuietHandoff.quiet(socketPath: environment.socketPath)
            decision = decide(status.build, bundled, status.agentHosts, replaced: isReplaced,
                              whenQuiet: true, quiet: quiet, overdue: overdue)
            if case .keep(let why) = decision {
                logger.info("acpmux \(pid) runs build \(status.build ?? "?", privacy: .public); handed off when quiet: \(why, privacy: .public)")
                quietWait?.deferred(home: home, pid: pid)
                return .waitingForQuiet
            }
        }
        guard decision == .restart else { return .kept }
        guard handedOff.withLock({ $0.insert(key).inserted }) else { return .kept }
        logger.info("acpmux \(pid) runs build \(status.build ?? "?", privacy: .public)\(isReplaced ? " from a replaced bundle" : "", privacy: .public)\(status.agentHosts ? "" : " without agent hosts", privacy: .public); handing off to \(bundled ?? "?", privacy: .public)")
        do {
            // Never `endAgents`: agents under agent hosts keep running, and every chat's session,
            // log and queue stay on disk for the next daemon.
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath, home: environment.home)
        } catch {
            logger.error("acpmux handoff request failed: \(String(describing: error), privacy: .public)")
            return .kept
        }
        // The old daemon holds its lock until it exits; the new one needs it.
        return await AgentPaneProcessExit(pid: pid).event(within: .seconds(15)) ? .stopped : .kept
    }
}

/// Waits for a process to exit through the kernel's exit event (no polling).
public nonisolated struct AgentPaneProcessExit: Sendable {
    public let pid: Int32

    public init(pid: Int32) { self.pid = pid }

    private final class Once: Sendable {
        let done = Mutex(false)
        let deadline = Mutex<Task<Void, Never>?>(nil)
        func first() -> Bool {
            done.withLock { flag in
                defer { flag = true }
                return !flag
            }
        }
    }

    /// True at the exit; false when `timeout` passes first. A nil `timeout` waits for the exit only.
    public func event(within timeout: Duration?) async -> Bool {
        let pid = self.pid
        return await withCheckedContinuation { continuation in
            let once = Once()
            let queue = DispatchQueue(label: "cmux.next.agent-pane.acpmux-exit.\(pid)")
            nonisolated(unsafe) let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            let finish: @Sendable (Bool) -> Void = { exited in
                guard once.first() else { return }
                source.cancel()
                once.deadline.withLock { $0?.cancel() }
                continuation.resume(returning: exited)
            }
            if let timeout {
                // task-owner: the bounded deadline of this one wait; cancelled when the exit arrives
                let timer = Task {
                    // wakeup-allow: one bounded deadline per handoff (rare); cancelled at the exit event
                    try? await Task.sleep(for: timeout)
                    if !Task.isCancelled { finish(false) }
                }
                once.deadline.withLock { $0 = timer }
            }
            source.setEventHandler { finish(true) }
            source.resume()
            if kill(pid, 0) != 0 && errno == ESRCH { finish(true) }
        }
    }
}
