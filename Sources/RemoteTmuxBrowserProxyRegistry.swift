import CmuxCore
import CmuxRemoteWorkspace
import Foundation

/// Owns the lifecycle of ssh-tmux's local browser-preview proxy: one
/// credentialed listener per HOST (keyed by `RemoteTmuxHost.connectionHash`),
/// refcounted by the mirror workspaces using it. Each browser request opens an
/// owner-only SSH stream through the shared ControlMaster.
///
/// Start order (both must be ready before anything is published):
/// 1. Allocate a loopback port.
/// 2. Start `RemoteTmuxBrowserProxyListener` with a fresh credential.
/// 3. Publish the endpoint only after the listener is ready.
/// On a local port collision, retry with
/// fresh ports. Single-flight per host via the stored `Task`.
@MainActor
final class RemoteTmuxBrowserProxyRegistry {
    private struct Entry {
        var host: RemoteTmuxHost
        var listener: RemoteTmuxBrowserProxyListener?
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
    private let loopbackPortAllocator = LoopbackPortAllocator()

    /// Set once by `RemoteTmuxController` right after construction — a plain
    /// `init` parameter would need `self` before it exists, since the provider
    /// calls back into the controller's own transport registry. Implicitly
    /// unwrapped because every real path sets it before `acquire` can run.
    /// Creates a transport if none exists, so only `start()` may use it.
    var transportProvider: ((RemoteTmuxHost) -> any RemoteTmuxBrowserProxyTransport)!

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
        onEndpointChange?(hash, nil)
    }

    func releaseAll() {
        for hash in Array(entriesByConnectionHash.keys) {
            releaseHost(connectionHash: hash)
        }
    }

    /// Invalidates a host's existing browser listener without
    /// tearing down the whole entry — used both when a reconnected SSH
    /// session makes them stale, and when a live listener fails or is
    /// cancelled unexpectedly after startup. Unlike ``releaseHost(connectionHash:)``, this must
    /// never drop the host's `retainingWorkspaceIDs`: every mirror workspace
    /// still using this host keeps its retention on the SAME entry and gets
    /// rebuilt exactly once here, rather than each caller racing to tear the
    /// whole entry down and re-derive retention from whichever workspace
    /// happens to reacquire first — which would silently drop every OTHER
    /// retaining workspace's claim, and could leave an already-open browser
    /// panel elsewhere on the same host permanently without a proxy. Safe to
    /// call for a host with no entry (nothing to invalidate) or no retainers
    /// (the entry is simply dropped, matching `releaseHost`).
    func invalidateAndRebuild(connectionHash hash: String) {
        guard var entry = entriesByConnectionHash[hash] else { return }
        entry.task?.cancel()
        entry.listener?.stop()
        entry.listener = nil
        entry.task = nil
        entry.startupID = nil
        guard let anyRetainer = entry.retainingWorkspaceIDs.first else {
            entriesByConnectionHash.removeValue(forKey: hash)
            onEndpointChange?(hash, nil)
            return
        }
        entriesByConnectionHash[hash] = entry
        onEndpointChange?(hash, nil)
        // Kicks off one fresh acquisition against the preserved entry;
        // `acquire` reuses it (rather than creating a new one) because its
        // `task` is nil here, and every existing retainer — not just this
        // one id — gets the endpoint this attempt eventually publishes.
        acquire(host: entry.host, workspaceID: anyRetainer)
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
            guard let listenerPort = loopbackPortAllocator.allocate() else {
                lastError = RemoteTmuxError.unreachable("could not allocate local ports for the browser proxy")
                continue
            }

            let credential = BrowserProxyCredential.random()
            let streamOpener = try await transport.makeBrowserProxyStreamOpener()
            let listener = RemoteTmuxBrowserProxyListener(
                localPort: listenerPort,
                credential: credential,
                streamOpener: streamOpener
            )
            listener.onUnexpectedFailure = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // Only this attempt's own listener triggers a teardown —
                    // a later reacquire may have already replaced or removed
                    // this host's entry.
                    guard self.entriesByConnectionHash[hash]?.startupID == startupID else { return }
                    // Not `releaseHost` — see `invalidateAndRebuild`'s doc.
                    self.invalidateAndRebuild(connectionHash: hash)
                }
            }
            do {
                try await listener.start()
            } catch {
                lastError = error
                continue
            }

            // `releaseHost` may have cancelled this task and removed the
            // registry entry while the listener was starting (the last
            // retaining workspace closed mid-acquire), or a newer `acquire()`
            // may have replaced this entry with its own attempt — commit
            // only if this attempt's id still owns the entry, or the
            // listener and forward just opened would run with nothing left
            // to own them, or would stomp a newer attempt's resources.
            guard !Task.isCancelled, entriesByConnectionHash[hash]?.startupID == startupID else {
                listener.stop()
                throw CancellationError()
            }
            entriesByConnectionHash[hash]?.listener = listener
            return BrowserProxyEndpoint(host: "127.0.0.1", port: listenerPort, credential: credential)
        }
        throw lastError
    }
}
