import CmuxCore
import CmuxRemoteWorkspace
import Foundation

/// Owns the lifecycle of ssh-tmux's local browser-preview proxy: one forward
/// per HOST (keyed by `RemoteTmuxHost.connectionHash`), refcounted by the
/// mirror workspaces using it — a SOCKS proxy is host-wide, not
/// session-wide, so N mirror workspaces on one host share one listener, one
/// dynamic forward, and one local port.
///
/// Start order — nothing is published until listener and forward are both up:
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
        /// most recently completed) `start()`. Without it, a
        /// teardown-then-reacquire race lets a stale attempt's callbacks act on
        /// a newer attempt's entry — clearing its `task` and broadcasting a
        /// false nil endpoint, or committing a superseded listener/forward over
        /// it. Every commit and every callback checks this id first.
        var startupID: UUID?
    }

    private var entriesByConnectionHash: [String: Entry] = [:]
    private let loopbackPortAllocator = LoopbackPortAllocator()

    /// Set once by `RemoteTmuxController` right after construction — a plain
    /// `init` parameter would need `self` before it exists, since the provider
    /// calls back into the controller's own transport registry. Implicitly
    /// unwrapped because every real path sets it before `acquire` can run.
    /// Creates a transport if none exists, so only `start()` may use it.
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
                // `start()` already checked ownership, but a newer attempt can
                // take over in the gap before this resumes — recheck before
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

    /// Invalidates a host's `-D` forward and SOCKS listener without tearing
    /// down the whole entry — used when a reconnected SSH session makes them
    /// stale, and when a live listener fails unexpectedly after startup.
    ///
    /// Unlike ``releaseHost(connectionHash:)``, this keeps the host's
    /// `retainingWorkspaceIDs`: dropping them would strip every OTHER mirror
    /// workspace's claim on this host and leave their already-open browser
    /// panels permanently without a proxy. Safe for a host with no entry, or
    /// with no retainers (the entry is then simply dropped).
    func invalidateAndRebuild(connectionHash hash: String) {
        guard var entry = entriesByConnectionHash[hash] else { return }
        entry.task?.cancel()
        entry.listener?.stop()
        if let forwardPort = entry.forwardPort, let transport = existingTransport(entry.host) {
            Task { await transport.cancelDynamicForward(localPort: forwardPort) }
        }
        entry.listener = nil
        entry.forwardPort = nil
        entry.task = nil
        entry.startupID = nil
        guard let anyRetainer = entry.retainingWorkspaceIDs.first else {
            entriesByConnectionHash.removeValue(forKey: hash)
            onEndpointChange?(hash, nil)
            return
        }
        entriesByConnectionHash[hash] = entry
        onEndpointChange?(hash, nil)
        // `acquire` reuses the preserved entry (its `task` is nil here), so
        // every existing retainer — not just this arbitrary one — gets the
        // endpoint this attempt eventually publishes.
        acquire(host: entry.host, workspaceID: anyRetainer)
    }

    private func start(host: RemoteTmuxHost, connectionHash hash: String, startupID: UUID) async throws -> BrowserProxyEndpoint {
        // Before `transportProvider(host)`, not after: it creates-and-registers
        // a transport if none exists, so a `releaseHost` landing since
        // `acquire()` returned would be silently undone here — resurrecting a
        // transport, and possibly a ControlMaster, for a torn-down host.
        try Task.checkCancellation()
        let transport = transportProvider(host)
        guard try await transport.ensureMasterReady() else {
            throw RemoteTmuxError.unreachable("ssh-tmux ControlMaster is not ready for the browser proxy")
        }
        try Task.checkCancellation()

        var lastError: Error = RemoteTmuxError.unreachable("could not start the browser proxy")
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard let forwardPort = loopbackPortAllocator.allocate(),
                  let listenerPort = loopbackPortAllocator.allocate(),
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

            do {
                try await transport.openDynamicForward(localPort: forwardPort)
            } catch let error as RemoteTmuxDynamicForwardError where error.failure == .portInUse {
                listener.stop()
                lastError = error
                continue
            } catch {
                // `openDynamicForward` can throw cancellation after `ssh -O
                // forward` already succeeded — its `runProcess` only checks
                // cancellation once the process has exited — leaving a live
                // forward behind. Cancel unconditionally: if none was ever
                // installed, `-O cancel` has nothing to act on.
                listener.stop()
                Task { await transport.cancelDynamicForward(localPort: forwardPort) }
                throw error
            }

            // The entry may have been torn down (last retainer closed
            // mid-acquire) or replaced by a newer `acquire()` while the forward
            // was opening. Commit only if this attempt still owns it —
            // otherwise the listener and forward just opened would leak with
            // nothing owning them, or stomp a newer attempt's.
            guard !Task.isCancelled, entriesByConnectionHash[hash]?.startupID == startupID else {
                listener.stop()
                Task { await transport.cancelDynamicForward(localPort: forwardPort) }
                throw CancellationError()
            }
            entriesByConnectionHash[hash]?.listener = listener
            entriesByConnectionHash[hash]?.forwardPort = forwardPort
            // The listener's port, never the `-D` port — see `RemoteTmuxBrowserProxyListener`.
            return BrowserProxyEndpoint(host: "127.0.0.1", port: listenerPort)
        }
        throw lastError
    }
}
