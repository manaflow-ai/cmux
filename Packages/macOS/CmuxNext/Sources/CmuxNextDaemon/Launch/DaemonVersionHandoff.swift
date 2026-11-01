import CmuxNextWakeups
import Foundation
import os
import CmuxNextCompat

/// What the app does with a running daemon of another build after an update
/// (plans/cmux-next/durable-sessions.md section 3).
public enum DaemonVersionDecision: Sendable, Equatable {
    /// Keep the running daemon; the reason is for the log.
    case keep(String)
    /// Hand off: the running daemon (`running` build id, or its commit) exits,
    /// keeping its terminal hosts, and a daemon of the bundled build (`bundled`)
    /// adopts them.
    case restart(running: String, bundled: String)
}

/// One launcher's handoff state: the bundled builds it already handed off
/// to (never twice, so a mismatched version string cannot loop), and the
/// daemon that is exiting for a handoff, which the next `ensure` waits out.
final class DaemonHandoffState: Sendable {
    private struct State {
        var handedOffTo: Set<String> = []
        var exiting: Int32?
    }

    private let state = Mutex(State())

    /// Records a handoff to `bundled` of the daemon `pid`; false when this
    /// launcher already handed off to that build.
    func begin(bundled: String, pid: Int32) -> Bool {
        state.withLock {
            guard $0.handedOffTo.insert(bundled).inserted else { return false }
            $0.exiting = pid
            return true
        }
    }

    func cancel(pid: Int32) {
        state.withLock { if $0.exiting == pid { $0.exiting = nil } }
    }

    /// The daemon exiting for a handoff. It stays set until a connect saw
    /// it exit (`cancel`), so every connect waits it out, including the
    /// exiting daemon's own connection reconnecting at the same moment.
    var exiting: Int32? {
        state.withLock { $0.exiting }
    }
}

/// Waits for a process to exit through the kernel's exit event (no polling).
enum ProcessExit {
    /// One wait's once-only completion and its deadline task.
    private final class Once: Sendable {
        let done = Mutex(false)
        func first() -> Bool {
            done.withLock { flag in
                defer { flag = true }
                return !flag
            }
        }
    }

    /// True when `pid` exited within `timeout` (or was already gone).
    static func exitEvent(pid: Int32, within timeout: Duration, clock: any Clock<Duration>) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once()
            let deadline = DemandTimer(owner: "daemon.handoff.exit", clock: clock)
            let queue = DispatchQueue(label: "com.cmuxterm.next.daemon.exit.\(pid)")
            nonisolated(unsafe) let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            let finish: @Sendable (Bool) -> Void = { exited in
                guard once.first() else { return }
                source.cancel()
                deadline.cancel()
                continuation.resume(returning: exited)
            }
            // A bounded deadline, not synchronization: a daemon that does
            // not exit is left to `ensure`, which reports it.
            deadline.schedule(after: timeout) { finish(false) }
            source.setEventHandler { finish(true) }
            source.resume()
            // Registered before this check, so an exit between the two is
            // still seen; a process that is already gone gives no event.
            if kill(pid, 0) != 0 && errno == ESRCH { finish(true) }
        }
    }
}

extension DaemonLauncher {
    /// Whether the running owner is another build than the bundled binary. The build identity
    /// (`build_id`) decides when both sides have one: it is the stamped commit for a packaged build
    /// and the commit plus `-dirty.<hash>` for an unstamped one, so two builds of one commit with
    /// other edits differ. An owner older than `daemon-build-v1` has no identity, and the stamped
    /// commits decide. With neither, the owner is kept and the reason names the unknown side.
    public static func versionDecision(running: DaemonBuildStamp, bundled: DaemonBuildStamp?) -> DaemonVersionDecision {
        if let runningID = running.id, let bundledID = bundled?.id {
            return runningID == bundledID ? .keep("same build") : .restart(running: runningID, bundled: bundledID)
        }
        guard let running = running.commit else { return .keep("running build unknown") }
        guard let bundled = bundled?.commit else { return .keep("bundled build unknown") }
        return running == bundled ? .keep("same build") : .restart(running: running, bundled: bundled)
    }

    /// After an update the app finds the daemon an older app started: hand
    /// it off to the bundled build so the update reaches it. Terminals keep
    /// running: `shutdown-daemon` without `end_terminals` leaves every
    /// terminal host alive, the connection reconnects through this
    /// launcher's endpoint provider, which waits for the old daemon to exit
    /// and runs `server ensure` from the bundled binary, and the new daemon
    /// adopts the hosts. `bundled` overrides the bundled binary's own build
    /// (the app passes the one it read at launch; tests pass another build).
    public func handOffIfStale(identity: DaemonIdentity, using connection: DaemonConnection,
                               bundled override: DaemonBuildStamp? = nil) async -> DaemonVersionDecision {
        let bundled: DaemonBuildStamp?
        if let override {
            bundled = override
        } else {
            bundled = try? await bundledBuild()
        }
        let decision = Self.versionDecision(running: DaemonBuildStamp(identity: identity), bundled: bundled)
        guard case .restart(let running, let target) = decision else { return decision }
        guard handoff.begin(bundled: target, pid: identity.pid) else {
            return .keep("already handed off to \(target)")
        }
        let logger = Logger(subsystem: "com.cmuxterm.next", category: "daemon")
        logger.info("daemon \(identity.pid) runs build \(running, privacy: .public); handing off to \(target, privacy: .public)")
        // Quiet (DaemonConnection.quietHandoff): no request of this connection is cut.
        let handoff = handoff
        return await connection.quietHandoff({ () async -> DaemonVersionDecision in
            do {
                let reply = try await connection.request(
                    ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation))
                guard reply.accepted != false else {
                    handoff.cancel(pid: identity.pid)
                    return .keep("the daemon refused the handoff")
                }
            } catch {
                handoff.cancel(pid: identity.pid)
                return .keep("handoff request failed: \(error)")
            }
            return decision
        }, accepted: { $0 == decision })
    }

    /// The running owner lacks `capability`, which the bundled build serves (an older build, or a
    /// dev daemon whose build is unknown, so `handOffIfStale` kept it): hand it off to the bundled
    /// build the same way, once per daemon. Terminals keep running and the next `ensure` starts
    /// the bundled build with this launcher's arguments. False for an external binary (it would
    /// start as itself again) and when the daemon refused. True while that daemon is still
    /// exiting for this handoff (a page retry during the exit), so the caller keeps waiting.
    public func handOffForCapability(_ capability: String, identity: DaemonIdentity,
                                     using connection: DaemonConnection) async -> Bool {
        guard configuration.binaryIsBundled, !identity.supports(capability) else { return false }
        if handoff.exiting == identity.pid { return true }
        // Once per launcher: the bundled build serves the capability, so a second owner without it
        // is not ours to restart again (no loop).
        guard handoff.begin(bundled: "capability:\(capability)", pid: identity.pid) else { return false }
        return await requestHandoff(identity: identity, using: connection)
    }

    /// The running owner does not verify this app's install key (an older build or `cmux chief`
    /// started it without one): hand it off once per launcher, the same way, so the next `ensure`
    /// starts it with the key on stdin. Only a launcher that holds a key (an unsigned build); the
    /// caller decides when a restart is safe. False when the daemon refused.
    public func handOffForInstallKey(identity: DaemonIdentity, using connection: DaemonConnection) async -> Bool {
        guard configuration.installKey != nil,
              handoff.begin(bundled: "install-key", pid: identity.pid) else { return false }
        return await requestHandoff(identity: identity, using: connection)
    }

    /// The person confirmed "Restart cmux-tui" (a server update, plans/cmux-next/server-updates-DESIGN.md):
    /// hand the running daemon off so the next `ensure` starts the bundled build. Terminals keep
    /// running, as in every handoff. Once per daemon process; false for an external binary (it
    /// would start as itself again) and when the daemon refused.
    public func handOffForUpdate(identity: DaemonIdentity, using connection: DaemonConnection) async -> Bool {
        guard configuration.binaryIsBundled,
              handoff.begin(bundled: "update:\(identity.pid)", pid: identity.pid) else { return false }
        return await requestHandoff(identity: identity, using: connection)
    }

    /// The handshake refused the running owner: it speaks another protocol or lacks a capability
    /// this app requires, as an owner an older build started does after an update that changed the
    /// protocol. Hand it off to the bundled build the same way as an owner of another build
    /// (`handOffIfStale`), on the refused connection: `shutdown-daemon` without `end_terminals`
    /// leaves every terminal host alive, the next connect waits for the owner to exit and runs
    /// `server ensure` from the bundled binary, and the new owner adopts the hosts. Only for the
    /// bundled binary (an external one would start as itself again), only an owner of this
    /// launcher's session (never one that serves another build's or home's session), and once per
    /// launcher (the bundled build is compatible, so a second incompatible owner is not ours to
    /// restart again). True while that owner is still exiting for this handoff; false when the
    /// daemon refused, so the refusal shows.
    func handOffIncompatible(identity: DaemonIdentity, on transport: LineTransport) async -> Bool {
        guard configuration.binaryIsBundled, identity.pid > 1, identity.session == configuration.session else { return false }
        if handoff.exiting == identity.pid { return true }
        guard handoff.begin(bundled: "incompatible", pid: identity.pid) else { return false }
        return await shutDown(identity) { try await DaemonConnection.perform($0, on: transport) }
    }

    /// `configuration` with this launcher's incompatible-owner handoff (`handOffIncompatible`), for
    /// the app's own connections to its local daemon.
    public func handingOffIncompatibleOwners(_ configuration: DaemonConnection.Configuration) -> DaemonConnection.Configuration {
        var configuration = configuration
        let launcher = self
        configuration.incompatibleOwner = { identity, transport in
            await launcher.handOffIncompatible(identity: identity, on: transport)
        }
        return configuration
    }

    /// Sent with no request of `connection` in flight; requests made meanwhile go to the next
    /// daemon (`DaemonConnection.quietHandoff`), so a handoff never cuts a Home send.
    private func requestHandoff(identity: DaemonIdentity, using connection: DaemonConnection) async -> Bool {
        await connection.quietHandoff { [self] in
            await shutDown(identity) { try await connection.request($0) }
        }
    }

    /// `shutdown-daemon` (no `end_terminals`: the terminals live on) for `identity` through `send`.
    /// A refusal or a failed request ends the handoff (`DaemonHandoffState.cancel`).
    private func shutDown(_ identity: DaemonIdentity,
                          send: (ShutdownDaemonRequest) async throws -> ShutdownDaemonRequest.Response) async -> Bool {
        do {
            let reply = try await send(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation))
            guard reply.accepted != false else {
                handoff.cancel(pid: identity.pid)
                return false
            }
        } catch {
            handoff.cancel(pid: identity.pid)
            return false
        }
        return true
    }
}
