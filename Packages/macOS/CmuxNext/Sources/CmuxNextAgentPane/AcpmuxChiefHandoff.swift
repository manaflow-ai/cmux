public import Foundation
import os
import Synchronization

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
    /// Daemons (by pid) this app process already handed off: never twice.
    private static let handedOff = Mutex<Set<Int32>>([])

    let environment: AcpmuxEnvironment
    let chiefMuxHome: String

    public init(environment: AcpmuxEnvironment, chiefMuxHome: String) {
        self.environment = environment
        self.chiefMuxHome = chiefMuxHome
    }

    /// Whether a daemon reporting `reported` needs the handoff.
    static func needsHandoff(reported: String?, expected: String) -> Bool {
        reported.map { URL(fileURLWithPath: $0).standardizedFileURL.path } != URL(fileURLWithPath: expected).standardizedFileURL.path
    }

    /// Stops the running Chief-home daemon when it lacks this Chief home.
    /// Returns true when it stopped one. Nothing runs: false.
    @concurrent public func handOffIfStale() async -> Bool {
        guard let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath),
              Self.needsHandoff(reported: status.chiefMuxHome, expected: chiefMuxHome) else { return false }
        guard status.agentHosts, let pid = status.pid else {
            Self.logger.error("Chief acpmux \(status.pid ?? -1) lacks the Chief home and has no agent hosts; it keeps running")
            return false
        }
        guard Self.handedOff.withLock({ $0.insert(pid).inserted }) else { return false }
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
