import CryptoKit
import Foundation
import os
import CmuxNextCompat

/// The person keys of the acpmux daemons this app launch started or enrolled (acpmux
/// `hub/person.rs`, cx-1l61, cx-fcaq): the daemon accepts an allow, a question's answer, or a
/// grant that widens what runs without asking only from a connection that proved it. Agents run
/// as the user, so a key lives in this process's memory only: it is never written to a file, a
/// log, the environment or argv, never handed to the page, and never inherited by a child process.
///
/// One key per daemon instance: a new key for each daemon this app starts, and for each enroll of
/// a daemon whose pid this app has not seen with that key. A key reaches a daemon on one of two
/// paths a Mac-side agent cannot take, and never otherwise crosses a socket:
/// - a Team-signed daemon: `_acpmux/person_enroll` on the unix socket, which the daemon accepts
///   only when the peer's audit token is this signed app. The app sends it only after it checked
///   the server peer (``AcpmuxServerPeer``): whatever listens on the socket path could be an
///   agent that shut the daemon down and bound the path.
/// - an unsigned (DEV) daemon: `--person-key-fd` when this process starts it. A DEV daemon that
///   another launch started holds another key, so the app hands it off (the agents under agent
///   hosts keep running) and starts one with a key of its own.
///
/// A connection proves the key with ``proof(socketPath:nonce:connection:)``: the HMAC of the
/// daemon's per-connection challenge, which proves nothing on any other connection.
nonisolated enum AcpmuxPersonKey {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")

    private struct Entry {
        var key: String
        /// The daemon instance it belongs to, once known.
        var pid: Int32?
    }

    /// Keys by daemon socket path.
    private static let keys = Mutex<[String: Entry]>([:])

    /// 32 random bytes as lowercase hex. On Apple platforms `SystemRandomNumberGenerator` is the
    /// kernel's cryptographic generator (`arc4random_buf`).
    static func newKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// A new key for the daemon this app is about to start on `socketPath`.
    static func spawnKey(for socketPath: String) -> String {
        let key = newKey()
        keys.withLock { $0[socketPath] = Entry(key: key, pid: nil) }
        return key
    }

    /// The key to enroll with the daemon `pid` on `socketPath`: the one this app gave that
    /// instance, else a new one (another instance, or one this app never keyed).
    static func enrollKey(for socketPath: String, pid: Int32?) -> String {
        keys.withLock { keys in
            if var entry = keys[socketPath], pid == nil || entry.pid == nil || entry.pid == pid {
                if entry.pid == nil { entry.pid = pid }
                keys[socketPath] = entry
                return entry.key
            }
            let key = newKey()
            keys[socketPath] = Entry(key: key, pid: pid)
            return key
        }
    }

    /// `_acpmux/person_prove`'s proof for one connection's challenge: lowercase hex
    /// HMAC-SHA256(key, "acpmux-person-v1" 0 nonce 0 connection). Nil without a key for
    /// `socketPath` (this app neither started nor enrolled that daemon).
    static func proof(socketPath: String, nonce: String, connection: String) -> String? {
        guard let key = keys.withLock({ $0[socketPath]?.key }) else { return nil }
        return proof(key: key, nonce: nonce, connection: connection)
    }

    static func proof(key: String, nonce: String, connection: String) -> String? {
        guard let keyBytes = hexBytes(key), keyBytes.count == 32 else { return nil }
        var message = Data("acpmux-person-v1".utf8)
        message.append(0)
        message.append(Data(nonce.utf8))
        message.append(0)
        message.append(Data(connection.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: keyBytes))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexBytes(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var out = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let byte = UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(byte)
            index += 2
        }
        return out
    }

    /// The daemon's reason when it cannot verify this app and holds another key.
    static let enrollUnavailable = "person.enroll_unavailable"

    /// Daemons (by pid) this process already handed off for the key: never twice.
    private static let handedOff = Mutex<Set<Int32>>([])

    /// Gives the running daemon its key, after the server peer check. Returns true when it stopped
    /// that daemon (an unsigned one with another key), so the caller starts a new one.
    /// `mayHandOff` false (a reconnect): never stops a daemon; a DEV daemon with another key keeps
    /// refusing this launch's allows until a pane that may start a daemon hands it off.
    static func enroll(_ status: AcpmuxStatus, environment: AcpmuxEnvironment, mayHandOff: Bool = true) async -> Bool {
        let key = enrollKey(for: environment.socketPath, pid: status.pid)
        do {
            // Sent only to a server peer that is the acpmux this app runs (cx-fcaq).
            _ = try await AcpmuxServerPeer.call(socketPath: environment.socketPath, method: "_acpmux/person_enroll",
                                                params: ["key": key], executable: environment.executable,
                                                deadline: .seconds(5))
            return false
        } catch let refusal as AcpmuxServerPeer.Refusal {
            logger.error("acpmux person_enroll not sent: \(String(describing: refusal), privacy: .public)")
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
