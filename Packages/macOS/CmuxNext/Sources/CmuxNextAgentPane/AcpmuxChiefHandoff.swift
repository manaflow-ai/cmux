public import Foundation
import os
import CmuxNextCompat

/// Hands off a Chief home's acpmux daemon that runs from a replaced bundle (an
/// update replaced the app it ran from, so the server peer check refuses it and
/// every Chief chat says acpmux did not start), or without this Chief home in
/// its own environment (an older build, or one an app started before it set
/// `ACPMUX_CHIEF_MUX_HOME`): acpmux's built-in Chief presets then cannot fill
/// their codex homes and a subagent's cmux links (acpmux
/// `config/chief_builtins.rs`). The same path as a version handoff
/// (``AcpmuxVersionHandoff``): only a daemon that runs its agents under agent
/// hosts is stopped (`_acpmux/shutdown`; its agents keep running and the next
/// daemon adopts them), and only by its own shutdown, never by a signal or a
/// process pattern. The next start of that daemon is the Chief host's (a
/// Chief tab never starts one, cx-ebm.54): `HomeBrainHost.start` ends the host
/// that ran on it and launches one, which starts it with the right environment.
public nonisolated struct AcpmuxChiefHandoff: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    /// Chief homes this app process already handed off (or decided to skip):
    /// at most once per Chief home, never per pid, so a host or LaunchAgent
    /// that respawns the daemon without the Chief home cannot make every start
    /// restart it again.
    private static let decided = Mutex<Set<String>>([])

    let environment: AcpmuxEnvironment
    let chiefMuxHome: String

    public init(environment: AcpmuxEnvironment, chiefMuxHome: String) {
        self.environment = environment
        self.chiefMuxHome = chiefMuxHome
    }

    /// Whether a daemon reporting `reported` needs the handoff. The same
    /// string the Chief host and this app give it (`home.muxHome.path`, not
    /// canonicalized): acpmux reports the value it was started with.
    static func needsHandoff(reported: String?, expected: String) -> Bool {
        reported != expected
    }

    /// What to do with the running Chief-home daemon.
    enum Decision: Equatable, Sendable {
        /// Keep it running (the reason, for the log). Nil: nothing is stale.
        case keep(String?)
        /// Stop it (`_acpmux/shutdown`) so the Chief host starts the bundled one.
        case handOff(Reason)
    }

    /// Why a Chief-home daemon is handed off.
    enum Reason: Equatable, Sendable {
        /// It runs without this Chief home in its environment.
        case lacksChiefHome
        /// Its executable's file is gone: an update (Sparkle, a reinstall, `reload.sh`) replaced
        /// the bundle it ran from. The server peer check cannot read such a peer's path
        /// (`proc_pidpath` fails), so every Chief chat says acpmux did not start until it ends.
        case replacedBundle
    }

    /// The handoff decision. `replaced` (``AcpmuxVersionHandoff/replaced(pid:)``) comes first:
    /// a daemon whose executable was deleted is no live build's own, so stopping it cannot make
    /// two builds that share the Chief home restart each other's daemon, as a plain build
    /// difference would (builds can share one Chief home: NIGHTLY's, or an explicit `CMUX_NEXT_CHIEF_HOME`).
    static func decide(reported: String?, expected: String, running: String?, bundled: String?,
                       agentHosts: Bool, replaced: Bool) -> Decision {
        let lacks = needsHandoff(reported: reported, expected: expected)
        guard lacks || replaced else { return .keep(nil) }
        guard agentHosts else { return .keep("it has no agent hosts, so its agents would end") }
        if replaced { return .handOff(.replacedBundle) }
        // The same build as this app's acpmux: a restart would start the same binary under the
        // same starter (an older Chief host or brain LaunchAgent that does not set the Chief
        // home), so it would not help.
        if let running, running == bundled {
            return .keep("it runs without ACPMUX_CHIEF_MUX_HOME and this app's build; until the Chief host restarts, its built-in codex turn and compactor presets fail closed and its other built-in Chief presets start without their Chief's MUX_HOME (restart the Chief host)")
        }
        return .handOff(.lacksChiefHome)
    }

    /// What the heal does with the running Chief-home daemon.
    public enum ReplacedAction: Equatable, Sendable {
        /// Nothing: it does not run from a replaced bundle, or stopping it would end its agents.
        case keep
        /// The Chief host was asked to hand off when its turn ends; the caller hands the daemon
        /// off after it exits (`ChiefAcpmuxHeal`, or `HomeBrainHost.start` at a relaunch).
        case waitForHost
        /// Stop it now (`_acpmux/shutdown`).
        case handOff
    }

    /// The heal's decision for a daemon that runs from a replaced bundle (`replaced`) with or
    /// without agent hosts. `hostWaits` asks the Chief host to hand off when idle; true when it
    /// took that, so its running turn ends on this daemon first.
    static func replacedAction(replaced: Bool, agentHosts: Bool, hostWaits: () async -> Bool) async -> ReplacedAction {
        guard replaced, agentHosts else { return .keep }
        return await hostWaits() ? .waitForHost : .handOff
    }

    /// Stops the running Chief-home daemon when it runs from a replaced bundle and has agent
    /// hosts (they are adopted by the next daemon), while the app runs: a Chief chat that the
    /// peer check refused asks for it (``AcpmuxHost``'s heal), so the chat heals without a
    /// relaunch. Unlike ``handOffIfStale()`` it is not limited to once per Chief home: the
    /// caller asks once per daemon pid. Returns `.handOff` when it stopped one, `.waitForHost`
    /// when the Chief host hands off when its turn ends, else `.keep`.
    ///
    /// - Parameter waitFor: called once a handoff is due; true when the handoff must wait (the
    ///   Chief host was asked to hand off when idle), as in ``handOffIfStale(waitFor:)``.
    @concurrent public func handOffReplaced(waitFor: @Sendable () async -> Bool) async -> ReplacedAction {
        guard let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath),
              let pid = status.pid else { return .keep }
        let replaced = AcpmuxVersionHandoff.replaced(pid: pid)
        switch await Self.replacedAction(replaced: replaced, agentHosts: status.agentHosts, hostWaits: waitFor) {
        case .keep:
            if replaced {
                Self.logger.error("Chief acpmux \(pid) runs from a replaced bundle but has no agent hosts; it keeps running so its agents do not end")
            }
            return .keep
        case .waitForHost:
            Self.logger.info("Chief acpmux \(pid) runs from a replaced bundle; the handoff waits until the Chief host's turn ends")
            return .waitForHost
        case .handOff:
            break
        }
        Self.logger.info("Chief acpmux \(pid) runs from a replaced bundle; handing it off now")
        do {
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath, home: environment.home)
        } catch {
            Self.logger.error("Chief acpmux handoff request failed: \(String(describing: error), privacy: .public)")
            return .keep
        }
        return await AgentPaneProcessExit(pid: pid).event(within: .seconds(15)) ? .handOff : .keep
    }

    /// Stops the running Chief-home daemon when it lacks this Chief home or runs from a replaced
    /// bundle. Returns true when it stopped one. Nothing runs: false.
    ///
    /// - Parameter waitFor: called once a handoff is due; true when the handoff must wait (the
    ///   Chief host was asked to hand off when idle, so its turn ends on this daemon first). A
    ///   handoff that waits is not counted as decided: the start after the host exits does it.
    @concurrent public func handOffIfStale(waitFor: @Sendable () async -> Bool) async -> Bool {
        guard let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath) else { return false }
        let replaced = status.pid.map(AcpmuxVersionHandoff.replaced(pid:)) ?? false
        let lacks = Self.needsHandoff(reported: status.chiefMuxHome, expected: chiefMuxHome)
        guard lacks || replaced else { return false }
        guard !Self.decided.withLock({ $0.contains(chiefMuxHome) }) else { return false }
        let bundled = await AcpmuxVersionHandoff.bundledBuild(environment)
        let decision = Self.decide(reported: status.chiefMuxHome, expected: chiefMuxHome, running: status.build,
                                   bundled: bundled, agentHosts: status.agentHosts, replaced: replaced)
        if case .handOff = decision, await waitFor() {
            Self.logger.info("Chief acpmux \(status.pid ?? -1) handoff waits: the Chief host hands off when its turn ends")
            return false
        }
        guard Self.decided.withLock({ $0.insert(chiefMuxHome).inserted }) else { return false }
        guard case .handOff(let reason) = decision, let pid = status.pid else {
            if case .keep(let why?) = decision {
                Self.logger.error("Chief acpmux \(status.pid ?? -1) for Chief home \(chiefMuxHome, privacy: .public) is stale but keeps running: \(why, privacy: .public)")
            }
            return false
        }
        Self.logger.info("Chief acpmux \(pid) \(reason == .replacedBundle ? "runs from a replaced bundle" : "lacks the Chief home", privacy: .public); handing it off")
        do {
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath, home: environment.home)
        } catch {
            Self.logger.error("Chief acpmux handoff request failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
    }
}
