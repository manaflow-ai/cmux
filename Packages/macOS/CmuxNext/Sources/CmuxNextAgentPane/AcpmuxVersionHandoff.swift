import Darwin
import Foundation
import CmuxNextWakeups
import os
import CmuxNextCompat

/// After an update: hand a running acpmux daemon of another build off to the
/// bundled build (plans/cmux-next/durable-sessions.md section 3), and one whose
/// executable was replaced with the app's bundle whatever its build
/// (``replaced(pid:)``), also mid-turn, with no wait for idle. A daemon that runs
/// its agents under agent hosts (`_acpmux/status` `agentHosts`) detaches them on
/// SIGTERM and the new daemon adopts them. One without agent hosts (a build from
/// before them, or `ACPMUX_AGENT_HOSTS=0`) ends its agents, but keeps its chats on
/// disk (`store.mode` `local`): the new daemon reads them back and each agent
/// resumes its chat on its next prompt, a turn running then is cut. Only a daemon
/// that keeps neither (a memory store without agent hosts) keeps running until it
/// exits on its own: its chats would be lost (``keepsItsChats(agentHosts:chatsOnDisk:)``).
nonisolated enum AcpmuxVersionHandoff {
    enum Decision: Equatable, Sendable {
        case keep(String)
        case restart
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    /// The handoffs this app process already made, by socket and bundled build: never twice on
    /// one socket. One key per socket, not per build: two homes (the app's and a Chief home's own
    /// acpmux) can each run a daemon from one replaced bundle, and with a key per build alone the
    /// first handoff barred the second, whose chats stayed refused until a relaunch (cosmic-gray,
    /// 2026-10-25).
    private static let handedOff = Mutex<Set<String>>([])

    /// `acpmux 0.1.0 (<build>)` -> `<build>`.
    static func build(fromVersion version: String) -> String? {
        guard let open = version.firstIndex(of: "("), let close = version.lastIndex(of: ")"), open < close else {
            return nil
        }
        let build = version[version.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return build.isEmpty ? nil : build
    }

    /// Whether a daemon keeps its chats across a restart: its agents under agent hosts, or its
    /// chats on disk to resume from. False only for a memory store without agent hosts.
    static func keepsItsChats(agentHosts: Bool, chatsOnDisk: Bool) -> Bool {
        agentHosts || chatsOnDisk
    }

    static func decide(_ running: String?, _ bundled: String?, _ agentHosts: Bool, chatsOnDisk: Bool,
                       replaced: Bool = false) -> Decision {
        let keeps = keepsItsChats(agentHosts: agentHosts, chatsOnDisk: chatsOnDisk)
        if replaced { return keeps ? .restart : .keep("its chats would be lost: a memory store without agent hosts") }
        guard let running else { return .keep("running build unknown") }
        guard let bundled else { return .keep("bundled build unknown") }
        if running == bundled { return .keep("same build") }
        guard keeps else { return .keep("its chats would be lost: a memory store without agent hosts") }
        return .restart
    }

    /// Whether the daemon's agent launch policy (`_acpmux/status` `agentLaunch`) is not the one this
    /// app would start it with (`environment`, its daemon environment). The daemon reads the
    /// policy from the environment it started with, and it outlives the app: a GUI test run of a
    /// tag starts it with `ACPMUX_AGENT_LAUNCH=deny`, and every later launch of that tag reused it,
    /// so each new chat said "agent launch is disabled in this build session" (cmuxterm-hq#5545).
    /// The other way round, a test app reusing a person's daemon would start real agents. A daemon
    /// that does not report its policy is taken as it is.
    static func launchPolicyDiffers(daemon: String?, environment: [String: String]) -> Bool {
        guard let daemon else { return false }
        return (daemon.lowercased() == "deny") != AcpmuxEnvironment.agentLaunchDisabled(environment)
    }

    /// Whether a lookup that may start daemons stops the one `status` describes: another build or a
    /// replaced bundle (``decide(_:_:_:chatsOnDisk:replaced:)``), or another agent launch policy
    /// (``launchPolicyDiffers(daemon:environment:)``) when its chats survive the restart.
    static func restarts(_ status: AcpmuxStatus, bundled: String?, replaced: Bool, policyDiffers: Bool) -> Bool {
        if decide(status.build, bundled, status.agentHosts, chatsOnDisk: status.chatsOnDisk, replaced: replaced) == .restart {
            return true
        }
        return policyDiffers && keepsItsChats(agentHosts: status.agentHosts, chatsOnDisk: status.chatsOnDisk)
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

    /// The bundled acpmux's build (`<executable> --version`).
    static func bundledBuild(_ environment: AcpmuxEnvironment) async -> String? {
        guard let outcome = try? await AsyncProcess().run(ProcessRequest(environment.executable, ["--version"])) else { return nil }
        return build(fromVersion: outcome.text)
    }

    /// Hands the daemon described by `status` off when it runs another build or
    /// a replaced bundle's executable, and keeps its agents across a restart.
    /// Returns true when it stopped that daemon, so the caller starts the
    /// bundled one.
    static func handOffIfStale(_ status: AcpmuxStatus, environment: AcpmuxEnvironment, daemons: AcpmuxLocalDaemons) async -> Bool {
        let bundled = await bundledBuild(environment)
        AgentPaneLaunchTimings.shared.mark("acpmux.bundled_build_read")
        let isReplaced = runsReplacedExecutable(status, environment: environment, log: true)
        let policy = launchPolicyDiffers(daemon: status.agentLaunch, environment: environment.childEnvironment)
        guard restarts(status, bundled: bundled, replaced: isReplaced, policyDiffers: policy), let pid = status.pid else {
            return false
        }
        if policy {
            logger.info("acpmux \(pid) runs agent launch \(status.agentLaunch ?? "?", privacy: .public); this app's is \(AcpmuxEnvironment.agentLaunchDisabled(environment.childEnvironment) ? "deny" : "allow", privacy: .public)")
        }
        let key = handOffKey(environment, bundled: bundled, pid: pid)
        // The key is used up and Settings' daemon line marked restarting in one step, so a read
        // that finds the key used finds the mark too (``AcpmuxDaemonSummary/current(_:daemons:)``). The
        // line says restarting until the lookup that starts the bundled one settles
        // (AgentPaneHost.findOrStart), or until this handoff fails.
        let inserted = handedOff.withLock { keys in
            let inserted = keys.insert(key).inserted
            if inserted { daemons.mark(home: environment.home, restarting: true) }
            return inserted
        }
        guard inserted else {
            logger.error("acpmux \(pid) at \(environment.socketPath, privacy: .public) still runs build \(status.build ?? "?", privacy: .public) after this app handed that socket off to \(bundled ?? "?", privacy: .public) once")
            return false
        }
        logger.info("acpmux \(pid) runs build \(status.build ?? "?", privacy: .public)\(isReplaced ? " from a replaced bundle" : "", privacy: .public)\(status.agentHosts ? "" : " without agent hosts; its chats resume from disk", privacy: .public); handing off to \(bundled ?? "?", privacy: .public)")
        do {
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath, home: environment.home)
            AgentPaneLaunchTimings.shared.mark("acpmux.handoff_shutdown_sent")
        } catch {
            logger.error("acpmux handoff request failed: \(String(describing: error), privacy: .public)")
            daemons.mark(home: environment.home, restarting: false)
            return false
        }
        // The old daemon holds its lock until it exits; the new one needs it.
        let exited = await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
        if !exited { daemons.mark(home: environment.home, restarting: false) }
        return exited
    }

    /// What a lookup would do with the daemon `status` describes (Settings' daemon line,
    /// ``AcpmuxDaemonSummary``): whether it runs a replaced bundle's executable, and whether
    /// ``handOffIfStale(_:environment:daemons:)`` would stop it now. An attached daemon is never
    /// handed off (a lookup never starts or stops one), nor a socket this launch handed off once.
    static func handsOff(_ status: AcpmuxStatus, environment: AcpmuxEnvironment,
                         bundled: String?) -> (replaced: Bool, handsOff: Bool) {
        let isReplaced = runsReplacedExecutable(status, environment: environment, log: false)
        let policy = launchPolicyDiffers(daemon: status.agentLaunch, environment: environment.childEnvironment)
        guard !environment.isAttached, restarts(status, bundled: bundled, replaced: isReplaced, policyDiffers: policy),
              let pid = status.pid else { return (isReplaced, false) }
        let key = handOffKey(environment, bundled: bundled, pid: pid)
        return (isReplaced, !handedOff.withLock { $0.contains(key) })
    }

    /// The once-per-socket key of a handoff (``handedOff``), per launch policy too: a handoff to
    /// the bundled build must not use up the one that later takes a daemon a GUI test restarted
    /// with launches off (cmuxterm-hq#5545).
    private static func handOffKey(_ environment: AcpmuxEnvironment, bundled: String?, pid: Int32) -> String {
        let policy = AcpmuxEnvironment.agentLaunchDisabled(environment.childEnvironment) ? "deny" : "allow"
        return "\(environment.socketPath) \(bundled ?? "pid \(pid)") launch=\(policy)"
    }

    /// Whether the daemon `status` describes runs an executable an update replaced, or (DEBUG)
    /// another binary than the `CMUX_NEXT_ACPMUX_BIN` override.
    private static func runsReplacedExecutable(_ status: AcpmuxStatus, environment: AcpmuxEnvironment, log: Bool) -> Bool {
        #if DEBUG
        let swapped = status.pid.map { swapsOverride(runningPath: executablePath(pid: $0),
                                                     override: AcpmuxEnvironment.debugExecutableOverride,
                                                     executable: environment.executable) } ?? false
        if swapped, log, let pid = status.pid {
            logger.info("acpmux \(pid) runs another binary than \(AcpmuxEnvironment.executableOverrideKey, privacy: .public) \(environment.executable.path, privacy: .public)")
        }
        return swapped || (status.pid.map(Self.replaced(pid:)) ?? false)
        #else
        return status.pid.map(Self.replaced(pid:)) ?? false
        #endif
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
    /// `armed` runs once the exit watch is resumed and before the check for an exit that came
    /// first, so a signal sent there cannot end the process unseen. The watch's registration with
    /// the kernel may still be in flight then: a caller that must signal only the process it
    /// found registers its own kernel exit watch (kqueue `EVFILT_PROC`) before it checks that process.
    /// It returns the answer when there is nothing to wait for (nil: wait).
    public func event(within timeout: Duration?, armed: () -> Bool? = { nil }) async -> Bool {
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
            if let answer = armed() {
                finish(answer)
                return
            }
            if kill(pid, 0) != 0 && errno == ESRCH { finish(true) }
        }
    }
}

/// Restart to Update hands the app's acpmux daemon to the new build as part of the relaunch, not
/// after it. The old app stops its daemon during the update's quit (`_acpmux/shutdown`, agents kept:
/// under agent hosts they detach and keep running, and a daemon with its chats on disk resumes
/// them), and waits for it to exit, bounded. The new build then finds no daemon and starts its own
/// bundled one, which adopts the agents: it never meets a daemon of the old build, so nothing waits
/// on ``AcpmuxVersionHandoff/handOffIfStale(_:environment:)`` at its first chat (2026-11-10: after
/// an update the daemon kept running the old build when that one-shot handoff timed out; that
/// handoff now retries, and stays the fallback for a relaunch that did not come through here).
public nonisolated struct AcpmuxUpdateHandoff: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// No daemon answered on the app's socket.
        case noDaemon
        /// The daemon keeps running; the reason says why.
        case kept(String)
        /// The daemon accepted the stop and exited.
        case handedOff
        /// The stop was not sent, or the daemon did not exit in time; the new build's handoff takes over.
        case failed(String)
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

    /// How long the update's quit waits for the daemon to stop and exit: inside the keep quit's 4 s
    /// (`QuitDeadline.keepQuitLimit`). A daemon still running past it is left to the new build's
    /// version handoff.
    public static let quitLimit: Duration = .milliseconds(1500)

    /// The app's daemon, or nil when it has none (``handOff(within:)`` answers ``Outcome/noDaemon``).
    let environment: AcpmuxEnvironment?

    public init(_ environment: AcpmuxEnvironment?) {
        self.environment = environment
    }

    /// ``handOff(within:)`` within ``quitLimit``, logged: the update quit's step.
    @concurrent public func handOffForQuit() async {
        let outcome = await handOff(within: Self.quitLimit)
        Self.logger.notice("update relaunch: acpmux \(String(describing: outcome), privacy: .public)")
    }

    /// Whether the update's relaunch stops the daemon `status` describes: never an attached daemon
    /// (another app's), nor one that would lose its chats (a memory store without agent hosts).
    static func decide(_ status: AcpmuxStatus, attached: Bool) -> AcpmuxVersionHandoff.Decision {
        if attached { return .keep("attached to another app's daemon") }
        guard status.pid != nil else { return .keep("its pid is unknown") }
        guard AcpmuxVersionHandoff.keepsItsChats(agentHosts: status.agentHosts, chatsOnDisk: status.chatsOnDisk) else {
            return .keep("its chats would be lost: a memory store without agent hosts")
        }
        return .restart
    }

    /// Stops the daemon of `environment` for the update's relaunch and waits up to `within` for it
    /// to exit (the kernel's exit event). Each request has a 1 s deadline.
    @concurrent func handOff(within: Duration) async -> Outcome {
        guard let environment, FileManager.default.fileExists(atPath: environment.socketPath) else { return .noDaemon }
        let status: AcpmuxStatus
        do {
            status = try await AcpmuxStatusClient.status(socketPath: environment.socketPath, deadline: .seconds(1))
        } catch AcpmuxStatusClient.Failure.unreachable {
            return .noDaemon
        } catch {
            return .failed(String(describing: error))
        }
        guard case .restart = Self.decide(status, attached: environment.isAttached), let pid = status.pid else {
            if case .keep(let why) = Self.decide(status, attached: environment.isAttached) { return .kept(why) }
            return .kept("its pid is unknown")
        }
        Self.logger.notice("update relaunch: handing acpmux \(pid) (build \(status.build ?? "?", privacy: .public)) to the new build")
        do {
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath, home: environment.home, deadline: .seconds(1))
        } catch {
            return .failed(String(describing: error))
        }
        guard await AgentPaneProcessExit(pid: pid).event(within: within) else {
            return .failed("acpmux \(pid) did not exit within \(within)")
        }
        return .handedOff
    }
}
