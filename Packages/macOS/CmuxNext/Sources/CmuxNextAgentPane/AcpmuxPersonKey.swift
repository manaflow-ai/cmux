import Foundation
import os
import CmuxNextCompat

/// This app launch's person key (acpmux `hub/person.rs`, cx-1l61): the daemon accepts an allow,
/// a question's answer, or a grant that widens what runs without asking only from a connection
/// that presented it. Agents run as the user, so the key lives in this process's memory only: it
/// is never written to a file, a log, the environment or argv, never handed to the page, and
/// never inherited by a child process (the daemon reads it from a pipe at spawn and closes it).
///
/// It reaches the daemon on one of two paths that a Mac-side agent cannot take:
/// - a Team-signed daemon: `_acpmux/person_enroll` on the unix socket, which the daemon accepts
///   only when the peer's audit token is this signed app;
/// - an unsigned (DEV) daemon: `--person-key-fd` when this process starts it. A DEV daemon that
///   another launch started holds another key, so the app hands it off (the agents under agent
///   hosts keep running) and starts one with this launch's key.
nonisolated enum AcpmuxPersonKey {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

    /// 32 random bytes as lowercase hex, made once per app launch. On Apple platforms
    /// `SystemRandomNumberGenerator` is the kernel's cryptographic generator (`arc4random_buf`).
    static let current: String = {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }()

    /// The daemon's reason when it cannot verify this app and holds another key.
    static let enrollUnavailable = "person.enroll_unavailable"

    /// Daemons (by pid) this process already handed off for the key: never twice.
    private static let handedOff = Mutex<Set<Int32>>([])

    /// Gives the running daemon this launch's key. Returns true when it stopped that daemon (an
    /// unsigned one with another key), so the caller starts a new one with ``current``.
    /// `mayHandOff` false (a reconnect): never stops a daemon; a DEV daemon with another key keeps
    /// refusing this launch's allows until a pane that may start a daemon hands it off.
    static func enroll(_ status: AcpmuxStatus, environment: AcpmuxEnvironment, mayHandOff: Bool = true) async -> Bool {
        do {
            _ = try await AcpmuxStatusClient.call(socketPath: environment.socketPath, method: "_acpmux/person_enroll",
                                                  params: ["key": current], deadline: .seconds(5), detailed: true)
            return false
        } catch let error as AcpmuxRPCError where error.name == enrollUnavailable {
            guard mayHandOff else {
                logger.error("acpmux \(status.pid ?? -1) has another person key; a reconnect does not hand it off")
                return false
            }
            guard status.agentHosts, let pid = status.pid else {
                // Its agents would end with it: keep it; allows stay refused until it restarts.
                logger.error("acpmux \(status.pid ?? -1) has another person key and no agent hosts; allow stays refused")
                return false
            }
            guard handedOff.withLock({ $0.insert(pid).inserted }) else { return false }
            logger.info("acpmux \(pid) has another launch's person key; handing it off")
            do {
                try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath)
            } catch {
                logger.error("acpmux person handoff request failed: \(String(describing: error), privacy: .public)")
                return false
            }
            return await AgentPaneProcessExit.exitEvent(pid: pid, within: .seconds(15))
        } catch {
            // An older daemon without the method has no person rule to satisfy.
            logger.info("acpmux person_enroll: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
