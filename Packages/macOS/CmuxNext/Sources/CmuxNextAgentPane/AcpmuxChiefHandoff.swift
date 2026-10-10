public import Foundation
import os
import CmuxNextCompat

/// Hands off a Chief home's acpmux daemon that runs without this Chief home in
/// its own environment (an older build, or one an app started before it set
/// `ACPMUX_CHIEF_MUX_HOME`): acpmux's built-in Chief presets then cannot fill
/// their codex homes and a subagent's cmux links (acpmux
/// `config/chief_builtins.rs`). The same path as a version handoff
/// (``AcpmuxVersionHandoff``): only a daemon that runs its agents under agent
/// hosts is stopped (`_acpmux/shutdown`; its agents keep running and the next
/// daemon adopts them), and only by its own shutdown, never by a signal or a
/// process pattern. The next start of that daemon (the Chief host's, or a
/// Chief tab's) has the right environment.
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

    /// Stops the running Chief-home daemon when it lacks this Chief home.
    /// Returns true when it stopped one. Nothing runs: false.
    @concurrent public func handOffIfStale() async -> Bool {
        guard let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath),
              Self.needsHandoff(reported: status.chiefMuxHome, expected: chiefMuxHome) else { return false }
        guard Self.decided.withLock({ $0.insert(chiefMuxHome).inserted }) else { return false }
        guard status.agentHosts, let pid = status.pid else {
            Self.logger.error("Chief acpmux \(status.pid ?? -1) lacks the Chief home and has no agent hosts; it keeps running")
            return false
        }
        // The same build as this app's acpmux: a restart would start the same
        // binary under the same starter (an older Chief host or brain
        // LaunchAgent that does not set the Chief home), so it would not help.
        let bundled = await AcpmuxVersionHandoff.bundledBuild(environment)
        if let build = status.build, build == bundled {
            Self.logger.error("Chief acpmux \(pid) for Chief home \(chiefMuxHome, privacy: .public) runs without ACPMUX_CHIEF_MUX_HOME and this app's build: not handed off; codex built-in presets fail closed until the Chief host restarts (restart the Chief host)")
            return false
        }
        Self.logger.info("Chief acpmux \(pid) lacks the Chief home; handing it off")
        do {
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath)
        } catch {
            Self.logger.error("Chief acpmux handoff request failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return await AgentPaneProcessExit.exitEvent(pid: pid, within: .seconds(15))
    }
}
