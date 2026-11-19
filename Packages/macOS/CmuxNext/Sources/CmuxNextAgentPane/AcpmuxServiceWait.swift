internal import CCmuxAgentPanePolicyFFI
import CmuxNextCompat
import Foundation

/// What the pane's "waiting for the agent service" line says while a handshake waits on this app's
/// acpmux (`acpmux.serviceWait`). Leo, 2026-11-18 ~23:10Z, on "Waiting for the agent service (1:10)
/// Restart agent service": "i cant connect to agent service? something? :(". The daemon was alive
/// and slow (`acpmux daemon status` took 4.9 to 11.8 s), so Restart was the wrong thing to offer.
///
/// The host probes here (the home's `daemon.pid` process, one connect to the home's socket); the
/// verdict is Rust's (cmux-agent-pane-policy `service_wait.rs`, op `service_wait`): busy (a process
/// listens, the reply is late: never Restart), starting (the process runs, its
/// socket does not take connections yet), down (neither: Restart at once). The page only draws it.
public nonisolated struct AgentServiceWait: Sendable, Equatable {
    /// `busy`, `starting` or `down`.
    public var state: String
    /// Whether the line offers Restart agent service.
    public var restart: Bool

    public init(state: String, restart: Bool) {
        self.state = state
        self.restart = restart
    }

    /// The reply the page reads (serviceWait.ts `readAgentServiceWait`).
    var reply: [String: Any] { ["state": state, "restart": restart] }
}

nonisolated enum AcpmuxServiceWait {
    /// What the host sees of `environment`'s daemon now.
    struct Probe: Equatable, Sendable {
        /// The home's `daemon.pid` names a running acpmux (or the bundle's multi-call `cmux`).
        var processAlive: Bool
        /// A connect to the home's socket succeeded: a process listens there.
        var socketAccepts: Bool
    }

    /// Looks at `environment`'s daemon: its pid file's process and one connect to its socket (the
    /// kernel takes the connection even when the daemon's workers are too busy to read it).
    @concurrent static func probe(_ environment: AcpmuxEnvironment) async -> Probe {
        let file = environment.home.appendingPathComponent("daemon.pid")
        let pid = (try? String(blockingContentsOf: file, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var alive = false
        if let pid, pid > 1, pid != getpid(), agentPaneProcessIsRunning(pid),
           let path = AcpmuxVersionHandoff.executablePath(pid: pid) {
            alive = ["acpmux", "cmux"].contains(URL(fileURLWithPath: path).lastPathComponent)
        }
        return Probe(processAlive: alive, socketAccepts: AcpmuxDaemonStop.listenerPID(socketPath: environment.socketPath) != nil)
    }

    /// Rust's verdict for `probe` after `waitedMs` of waiting; nil when the op is missing (an app FFI
    /// before `service_wait`) or refused the request: the page then draws its plain waiting line.
    static func verdict(_ probe: Probe, waitedMs: Int) -> AgentServiceWait? {
        let request: [String: Any] = [
            "process_alive": probe.processAlive,
            "socket_accepts": probe.socketAccepts,
            "waited_ms": max(0, waitedMs),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var out = CmuxAgentPaneBytes(ptr: nil, len: 0)
        let code = "service_wait".withCString { op in
            json.withUnsafeBytes { bytes in
                cmux_agent_pane_policy_call(nil, op, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, &out)
            }
        }
        defer { cmux_agent_pane_policy_bytes_free(out) }
        guard code == 0, let pointer = out.ptr,
              let reply = try? JSONSerialization.jsonObject(with: Data(bytes: pointer, count: out.len)) as? [String: Any],
              let state = reply["state"] as? String, let restart = reply["restart"] as? Bool else { return nil }
        return AgentServiceWait(state: state, restart: restart)
    }
}
