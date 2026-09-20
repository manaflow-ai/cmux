import CmuxCore
import CmuxRemoteWorkspace
import Foundation

/// Owns the lifecycle of ssh-tmux's local browser-preview proxy: one forward
/// per HOST (keyed by `RemoteTmuxHost.connectionHash`), refcounted by the
/// mirror workspaces using it — a SOCKS proxy is host-wide, not
/// session-wide, so N mirror workspaces on one host share one listener, one
/// dynamic forward, and one local port.
///
/// Start order (both must be ready before anything is published):
/// 1. Allocate two distinct loopback ports.
/// 2. Start `RemoteTmuxBrowserProxyListener` on the advertised port.
/// 3. Open the `ssh -D` dynamic forward on the hidden port.
/// 4. Only then publish the advertised endpoint.
/// On any failure, both are torn down; on a local port collision, retry with
/// fresh ports. Single-flight per host via the stored `Task`.
@MainActor
final class RemoteTmuxBrowserProxyRegistry {
    private struct Entry {
        var host: RemoteTmuxHost
        var listener: RemoteTmuxBrowserProxyListener?
        var forwardPort: Int?
        var task: Task<BrowserProxyEndpoint, Error>?
        var retainingWorkspaceIDs: Set<UUID> = []
        /// Identifies which `acquire()` call owns this entry's in-flight (or
        /// most recently completed) `start()`. Without this, a
        /// teardown-then-reacquire race lets a stale attempt's callbacks act
        /// on a newer attempt's entry: attempt A's failure handler would clear
        /// attempt B's `task` and broadcast a false nil endpoint, or A's
        /// `start()` would commit its listener/forward into B's (or a third
        /// attempt C's) entry after B already moved it forward. Every commit
        /// and every callback checks this id first.
        var startupID: UUID?
    }

    private var entriesByConnectionHash: [String: Entry] = [:]

    /// Set once by `RemoteTmuxController` right after construction (a plain
    /// `init` parameter would need `self` before it exists, since the
    /// provider calls back into the controller's own transport registry).
    /// Force-unwrapped deliberately: every real code path sets this before
    /// `acquire` can be called. Creates a transport if none exists yet — only
    /// safe for `start()`, which is establishing a genuinely new forward.
    var transportProvider: ((RemoteTmuxHost) -> RemoteTmuxSSHTransport)!

    /// Existing-transport-only lookup, for teardown. Never creates: `releaseHost`
    /// can run after the host's transport was already removed (it's wired from
    /// `RemoteTmuxTransportRegistry.onHostRemoved`), and calling `transportProvider`
    /// there would silently recreate — and leave registered — a transport for a
    /// host whose ControlMaster is already gone. `nil` means "nothing left to
    /// cancel through," which `releaseHost` treats as a no-op, not an error.
    var existingTransport: ((RemoteTmuxHost) -> RemoteTmuxSSHTransport?)!

    /// Fired once an endpoint is ready or a host's proxy fails/is torn down
    /// (`nil` endpoint), so every retaining workspace can republish
    /// `remoteProxyEndpoint`.
    var onEndpointChange: ((_ connectionHash: String, _ endpoint: BrowserProxyEndpoint?) -> Void)?

    init() {}

    /// Ensures a forward exists for `host` and returns the task producing its
    /// endpoint; concurrent callers for the same host share one task
    /// (single-flight). `workspaceID` is refcounted so the forward outlives
    /// any single workspace closing while others still use it.
    @discardableResult
    func acquire(host: RemoteTmuxHost, workspaceID: UUID) -> Task<BrowserProxyEndpoint, Error> {
        let hash = host.connectionHash
        var entry = entriesByConnectionHash[hash] ?? Entry(host: host)
        entry.retainingWorkspaceIDs.insert(workspaceID)

        if let task = entry.task {
            entriesByConnectionHash[hash] = entry
            return task
        }

        let startupID = UUID()
        entry.startupID = startupID
        let task = Task { [weak self] () -> BrowserProxyEndpoint in
            guard let self else { throw RemoteTmuxError.unreachable("browser proxy registry deallocated") }
            do {
                let endpoint = try await self.start(host: host, connectionHash: hash, startupID: startupID)
                // `start()` already verified ownership before returning, but
                // a newer attempt could have taken over in the gap between
                // that check and resuming here — check again before
                // publishing under this attempt's name.
                guard self.entriesByConnectionHash[hash]?.startupID == startupID else {
                    throw CancellationError()
                }
                self.onEndpointChange?(hash, endpoint)
                return endpoint
            } catch {
                if self.entriesByConnectionHash[hash]?.startupID == startupID {
                    self.entriesByConnectionHash[hash]?.task = nil
                    self.entriesByConnectionHash[hash]?.startupID = nil
                    self.onEndpointChange?(hash, nil)
                }
                throw error
            }
        }
        entry.task = task
        entriesByConnectionHash[hash] = entry
        return task
    }

    /// Drops `workspaceID`'s retention on whichever host(s) it held; a host
    /// with no remaining retainers is torn down.
    func release(workspaceID: UUID) {
        for hash in Array(entriesByConnectionHash.keys) {
            guard var entry = entriesByConnectionHash[hash], entry.retainingWorkspaceIDs.contains(workspaceID) else { continue }
            entry.retainingWorkspaceIDs.remove(workspaceID)
            entriesByConnectionHash[hash] = entry
            if entry.retainingWorkspaceIDs.isEmpty {
                releaseHost(connectionHash: hash)
            }
        }
    }

    /// Tears down one host's forward/listener regardless of remaining
    /// retainers. The transport-registry teardown paths (host removed, master
    /// exited, app quitting) call this directly, since a dead ControlMaster
    /// takes the forward with it either way.
    func releaseHost(connectionHash hash: String) {
        guard let entry = entriesByConnectionHash.removeValue(forKey: hash) else { return }
        entry.task?.cancel()
        entry.listener?.stop()
        if let forwardPort = entry.forwardPort, let transport = existingTransport(entry.host) {
            Task { await transport.cancelDynamicForward(localPort: forwardPort) }
        }
        onEndpointChange?(hash, nil)
    }

    func releaseAll() {
        for hash in Array(entriesByConnectionHash.keys) {
            releaseHost(connectionHash: hash)
        }
    }

    private func start(host: RemoteTmuxHost, connectionHash hash: String, startupID: UUID) async throws -> BrowserProxyEndpoint {
        // Checked before `transportProvider(host)` runs, not after: a
        // `releaseHost` landing between `acquire()` returning and this task
        // body starting cancels this task and removes its registry entry,
        // and `transportProvider` unconditionally creates-and-registers a
        // transport if none exists. Without this check first, that race
        // would resurrect and re-register — and can spawn a ControlMaster
        // for — a host whose transport was just torn down.
        try Task.checkCancellation()
        let transport = transportProvider(host)
        guard try await transport.ensureMasterReady() else {
            throw RemoteTmuxError.unreachable("ssh-tmux ControlMaster is not ready for the browser proxy")
        }
        try Task.checkCancellation()

        var lastError: Error = RemoteTmuxError.unreachable("could not start the browser proxy")
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard let forwardPort = LoopbackPortAllocator.allocate(),
                  let listenerPort = LoopbackPortAllocator.allocate(),
                  forwardPort != listenerPort else {
                lastError = RemoteTmuxError.unreachable("could not allocate local ports for the browser proxy")
                continue
            }

            let listener = RemoteTmuxBrowserProxyListener(localPort: listenerPort, dynamicForwardPort: forwardPort)
            listener.onUnexpectedFailure = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // Only this attempt's own listener triggers a teardown —
                    // a later reacquire may have already replaced or removed
                    // this host's entry.
                    guard self.entriesByConnectionHash[hash]?.startupID == startupID else { return }
                    self.releaseHost(connectionHash: hash)
                }
            }
            do {
                try await listener.start()
            } catch {
                lastError = error
                continue
            }

            do {
                try await transport.openDynamicForward(localPort: forwardPort)
            } catch let error as RemoteTmuxDynamicForwardError where error.failure == .portInUse {
                listener.stop()
                lastError = error
                continue
            } catch {
                // `openDynamicForward` can throw a plain cancellation even
                // after `ssh -O forward` already exited successfully — its
                // underlying `runProcess` only checks `Task.checkCancellation()`
                // once the process has already terminated, so a cancellation
                // landing in that window discards a forward that is actually
                // now live on the ControlMaster. Best-effort-cancel it
                // regardless of which failure this was: a forward that never
                // actually got installed leaves `-O cancel` nothing to act on.
                listener.stop()
                Task { await transport.cancelDynamicForward(localPort: forwardPort) }
                throw error
            }

            // `releaseHost` may have cancelled this task and removed the
            // registry entry while the forward above was opening (the last
            // retaining workspace closed mid-acquire), or a newer `acquire()`
            // may have replaced this entry with its own attempt — commit
            // only if this attempt's id still owns the entry, or the
            // listener and forward just opened would run with nothing left
            // to own them, or would stomp a newer attempt's resources.
            guard !Task.isCancelled, entriesByConnectionHash[hash]?.startupID == startupID else {
                listener.stop()
                Task { await transport.cancelDynamicForward(localPort: forwardPort) }
                throw CancellationError()
            }
            entriesByConnectionHash[hash]?.listener = listener
            entriesByConnectionHash[hash]?.forwardPort = forwardPort
            // The advertised endpoint speaks both SOCKS5 and HTTP CONNECT,
            // like the daemon-backed proxy — it's `RemoteTmuxBrowserProxyListener`'s
            // own port, never the `-D` forward's port, which has no HTTP
            // awareness at all.
            return BrowserProxyEndpoint(host: "127.0.0.1", port: listenerPort)
        }
        throw lastError
    }
}
