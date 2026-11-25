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
/// One key per daemon instance: a new key for each unsigned daemon this app starts, and for each enroll of
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
        /// The instance a reader that is not a pane re-enrolled already (``claimReenroll(for:pid:)``).
        var reenrolled: Int32?
        /// The instance that took this key (``EnrollOutcome/delivered``): a pane proves under it
        /// without asking for another enroll (``deliveredKey(for:)``).
        var delivered: Int32?
    }

    /// Keys by daemon socket path, and who hears of each key a daemon takes
    /// (``whenDelivered(socketPath:_:)``): one lock, so a watcher and a delivery never miss each other.
    private struct Store {
        var entries: [String: Entry] = [:]
        var watchers: [UUID: (socketPath: String, notify: @Sendable (String) -> Void)] = [:]

        subscript(socketPath: String) -> Entry? {
            get { entries[socketPath] }
            set { entries[socketPath] = newValue }
        }
    }

    private static let keys = Mutex(Store())

    /// This launch's key for the daemon on `socketPath`, made now when the app holds none yet (a
    /// pane that connected before the host's lookup keyed that daemon). The host's enroll then
    /// sends this same key (``enrollKey(for:pid:)`` adopts an entry with no pid), so the pane's
    /// proof and the enroll name one key in either order; acpmux holds the proof until the key
    /// lands (`hub/person.rs` `proves_when_keyed`).
    static func paneKey(for socketPath: String) -> String {
        enrollKey(for: socketPath, pid: nil)
    }

    /// The key a daemon on `socketPath` took from this launch, nil when none did yet.
    static func deliveredKey(for socketPath: String) -> String? {
        keys.withLock { keys in keys[socketPath].flatMap { $0.delivered == nil ? nil : $0.key } }
    }

    /// Calls `notify` with each key a daemon on `socketPath` takes from now on, until
    /// ``stopWatching(_:)``: a pane whose pending proof names an earlier key proves the new one.
    static func whenDelivered(socketPath: String, _ notify: @escaping @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        keys.withLock { $0.watchers[id] = (socketPath, notify) }
        return id
    }

    static func stopWatching(_ id: UUID) {
        _ = keys.withLock { $0.watchers.removeValue(forKey: id) }
    }

    private static func announceDelivery(socketPath: String, key: String) {
        let watchers = keys.withLock { $0.watchers.values.filter { $0.socketPath == socketPath }.map(\.notify) }
        for notify in watchers { notify(key) }
    }

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

    /// True once per daemon instance (`pid`) on `socketPath`: a reader that is not a pane (the consent
    /// line) re-enrolls a daemon that did not take its proof, but not again on every read while that
    /// daemon keeps refusing (a DEV one holding another launch's key).
    static func claimReenroll(for socketPath: String, pid: Int32) -> Bool {
        keys.withLock { keys in
            var entry = keys[socketPath] ?? Entry(key: newKey(), pid: pid)
            guard entry.reenrolled != pid else { return false }
            entry.reenrolled = pid
            keys[socketPath] = entry
            return true
        }
    }

    /// Gives back ``claimReenroll(for:pid:)``'s claim on `pid` when its enroll never reached the
    /// daemon (cancelled, or a refusal that may pass), so a later read tries once more.
    static func releaseReenroll(for socketPath: String, pid: Int32) {
        keys.withLock { keys in
            guard keys[socketPath]?.reenrolled == pid else { return }
            keys[socketPath]?.reenrolled = nil
        }
    }

    /// The transport a proof names: the one this app knows it uses, never a value from the
    /// challenge (a relay that hands a unix connection's challenge to the pane's WebSocket gets
    /// a proof for the other transport).
    enum Transport: String { case unix, app }

    /// `_acpmux/person_prove`'s proof for one connection's challenge: lowercase hex
    /// HMAC-SHA256(key, "acpmux-person-v1" 0 transport 0 nonce 0 connection). Nil without a key
    /// for `socketPath` (this app neither started nor enrolled that daemon).
    static func proof(socketPath: String, transport: Transport, nonce: String, connection: String) -> String? {
        guard let key = keys.withLock({ $0[socketPath]?.key }) else { return nil }
        return proof(key: key, transport: transport, nonce: nonce, connection: connection)
    }

    /// This app's key for the daemon on `socketPath` in a buffer of its own, zeroed when released,
    /// to sign one person decision (``AcpmuxSecretKey/decisionProof(instance:session:permission:option:nonce:answers:annotations:)``).
    /// Nil without a key for that daemon.
    static func secretKey(socketPath: String) -> AcpmuxSecretKey? {
        keys.withLock { $0[socketPath]?.key }.flatMap { AcpmuxSecretKey(hex: $0) }
    }

    static func proof(key: String, transport: Transport, nonce: String, connection: String) -> String? {
        guard let keyBytes = hexBytes(key), keyBytes.count == 32 else { return nil }
        var message = Data("acpmux-person-v1".utf8)
        message.append(0)
        message.append(Data(transport.rawValue.utf8))
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

    /// Waits between enroll attempts after a refusal that may pass on its own (the daemon timed
    /// out, closed the connection, or was restarting): bounded, about 7 s in all.
    static let enrollRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

    /// Gives the running daemon its key, after the server peer check. Returns true when it stopped
    /// that daemon (an unsigned one with another key, or one running a bundle an update replaced),
    /// so the caller starts a new one.
    /// `mayHandOff` false (a reconnect): never stops a daemon; a DEV daemon with another key keeps
    /// refusing this launch's allows until a pane that may start a daemon hands it off.
    ///
    /// A refusal is never skipped in silence: without the key every pane on that daemon proves
    /// nothing, and the person's typed prompts reach the agent as an unverified sender's
    /// (2026-11-10, after an update left the previous build's daemon running). A daemon running an
    /// executable an update replaced can never be checked, so it is handed off as above; any other
    /// refusal is tried again a few times (``enrollRetryDelays``).
    static func enroll(_ status: AcpmuxStatus, environment: AcpmuxEnvironment, mayHandOff: Bool = true,
                       retryDelays: [Duration] = enrollRetryDelays) async -> Bool {
        await enrollOutcome(status, environment: environment, mayHandOff: mayHandOff, retryDelays: retryDelays) == .handedOff
    }

    /// What one ``enroll(_:environment:mayHandOff:retryDelays:)`` came to.
    enum EnrollOutcome: Equatable {
        /// The daemon took the key.
        case delivered
        /// It stopped the daemon; the caller starts a new one.
        case handedOff
        /// The daemon refused for good (another binary, user or launch's key; an older daemon).
        case refused
        /// The key never reached the daemon and may on a later try: cancelled, or a refusal that may pass.
        case unsent
    }

    /// ``enroll(_:environment:mayHandOff:retryDelays:)`` that says whether the key reached the daemon.
    static func enrollOutcome(_ status: AcpmuxStatus, environment: AcpmuxEnvironment, mayHandOff: Bool = true,
                              retryDelays: [Duration] = enrollRetryDelays) async -> EnrollOutcome {
        let key = enrollKey(for: environment.socketPath, pid: status.pid)
        var delays = retryDelays[...]
        // One attempt, then one more per delay: every pass returns or uses up a delay.
        for _ in 0...retryDelays.count {
            do {
                // Sent only to a server peer that is the acpmux this app runs (cx-fcaq).
                _ = try await AcpmuxServerPeer.call(socketPath: environment.socketPath, method: "_acpmux/person_enroll",
                                                    params: ["key": key], executable: environment.executable,
                                                    deadline: .seconds(5))
                if let pid = status.pid { keys.withLock { $0[environment.socketPath]?.delivered = pid } }
                announceDelivery(socketPath: environment.socketPath, key: key)
                return .delivered
            } catch let refusal as AcpmuxServerPeer.Refusal {
                if let pid = status.pid, AcpmuxVersionHandoff.replaced(pid: pid) {
                    logger.error("acpmux person_enroll not sent: \(String(describing: refusal), privacy: .public); acpmux \(pid) runs a replaced bundle")
                    return await handOff(status, environment: environment, mayHandOff: mayHandOff,
                                         why: "runs a bundle an update replaced, which cannot take this launch's person key",
                                         replaced: true) ? .handedOff : .refused
                }
                // Another install's or another user's daemon refuses for good: no retry there.
                guard Self.mayPass(refusal), let delay = delays.popFirst(), !Task.isCancelled else {
                    logger.error("acpmux person_enroll not sent: \(String(describing: refusal), privacy: .public); this pane's prompts are not proven the person's")
                    return Self.mayPass(refusal) ? .unsent : .refused
                }
                logger.error("acpmux person_enroll not sent: \(String(describing: refusal), privacy: .public); trying again")
                // wakeup-allow: a bounded enroll retry (three waits at most, only after a refusal)
                try? await Task.sleep(for: delay)
            } catch let error as AcpmuxRPCError where error.name == enrollUnavailable {
                return await handOff(status, environment: environment, mayHandOff: mayHandOff,
                                     why: "has another launch's person key") ? .handedOff : .refused
            } catch {
                // An older daemon without the method has no person rule to satisfy.
                logger.info("acpmux person_enroll: \(String(describing: error), privacy: .public)")
                return error is CancellationError || Task.isCancelled ? .unsent : .refused
            }
        }
        return .unsent
    }

    /// Whether a peer refusal may pass on a later try: the daemon did not answer, closed, was
    /// restarting, or its peer could not be read yet. Another binary, user or older daemon stays.
    static func mayPass(_ refusal: AcpmuxServerPeer.Refusal) -> Bool {
        switch refusal {
        case .timedOut, .closed, .unreachable, .noPeer: true
        case .otherUser, .otherExecutable, .olderDaemon: false
        }
    }

    /// Stops the daemon `status` describes so the caller starts one that takes this launch's key:
    /// only with `mayHandOff`, only one with agent hosts (its agents keep running), once per pid.
    /// `replaced`: its executable was replaced by an update; it is asked to swap to the installed
    /// build itself first (``AcpmuxVersionHandoff/swapReplaced(_:pid:reason:)``), make-before-break.
    private static func handOff(_ status: AcpmuxStatus, environment: AcpmuxEnvironment, mayHandOff: Bool,
                                why: String, replaced: Bool = false) async -> Bool {
        guard mayHandOff else {
            logger.error("acpmux \(status.pid ?? -1) \(why, privacy: .public); a reconnect does not hand it off")
            return false
        }
        guard status.agentHosts, let pid = status.pid else {
            // Its agents would end with it: keep it; allows stay refused until it restarts.
            logger.error("acpmux \(status.pid ?? -1) \(why, privacy: .public) and no agent hosts; allow stays refused")
            return false
        }
        guard handedOff.withLock({ $0.insert(pid).inserted }) else { return false }
        logger.info("acpmux \(pid) \(why, privacy: .public); handing it off")
        if replaced, await AcpmuxVersionHandoff.swapReplaced(environment, pid: pid, reason: "person key: acpmux \(why)") {
            return true
        }
        do {
            try await AcpmuxStatusClient.shutdown(socketPath: environment.socketPath, home: environment.home,
                                                  reason: "person key: acpmux \(why)",
                                                  deadline: AcpmuxEnvironment.answerDeadline)
        } catch {
            logger.error("acpmux person handoff request failed: \(String(describing: error), privacy: .public)")
            // Nothing reached the daemon: a later lookup may try again.
            handedOff.withLock { _ = $0.remove(pid) }
            return false
        }
        return await AgentPaneProcessExit(pid: pid).event(within: .seconds(15))
    }
}
