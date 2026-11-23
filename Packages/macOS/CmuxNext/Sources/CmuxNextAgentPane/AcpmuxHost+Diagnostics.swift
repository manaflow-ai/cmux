import Foundation
import os

/// ``AcpmuxHost``'s log lines in the `agent-pane.acpmux` category that need nothing of its state.
nonisolated private let acpmuxHostDiagnostics = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

extension AcpmuxHost {
    /// The pane's error for a peer check that refused the daemon on `environment`'s socket,
    /// logged with who holds it, so "acpmux did not start" never hides a running daemon.
    /// `reason` replaces the refusal's own description (a replaced bundle names itself).
    /// `startsDaemons`: whether this host may replace the daemon (``restartAcpmux(owner:)``); the refusal
    /// then carries the binary on the socket as its owner, for Restart acpmux only.
    static func refused(_ refusal: AcpmuxServerPeer.Refusal, _ environment: AcpmuxEnvironment,
                        reason: String? = nil, startsDaemons: Bool = true) -> AgentPaneHostError {
        var holder: String?
        var refusedPath: String?
        if case .otherExecutable(let path) = refusal {
            holder = AcpmuxServerPeer.holderName(executablePath: path)
            refusedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        let found = AcpmuxSocketOwner.read(socketPath: environment.socketPath)
        // This app's own acpmux on the socket is never replaced by itself, and a refusal that named
        // a binary offers to replace only that one: a daemon that took the socket since is not it.
        let owner = found.flatMap { owner in
            owner.path == environment.executable.resolvingSymlinksInPath().path
                || refusedPath.map({ $0 != owner.path }) == true ? nil : owner
        }
        AcpmuxFailureLog(logPath: environment.logPath).record(.peerRefused, detail: "\(environment.socketPath): \(refusal.description)")
        acpmuxHostDiagnostics.error("acpmux at \(environment.socketPath, privacy: .public) refused: \(refusal.description, privacy: .public); held by \(holder ?? "unknown", privacy: .public); this app runs \(environment.executable.path, privacy: .public)")
        return .daemonRefused(holder: holder, socketPath: environment.socketPath, reason: reason ?? refusal.description,
                              executable: environment.executable.path, owner: startsDaemons ? owner : nil)
    }

    /// One Default-level line per reconnect handshake (the agent-service-wait harness reads it):
    /// whether it redialed the kept endpoint and how long the host took.
    static func logReconnect(kept: Bool, since started: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - started
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        acpmuxHostDiagnostics.notice("acpmux reconnect handshake kept=\(kept, privacy: .public) ms=\(String(format: "%.1f", ms), privacy: .public)")
    }
}
