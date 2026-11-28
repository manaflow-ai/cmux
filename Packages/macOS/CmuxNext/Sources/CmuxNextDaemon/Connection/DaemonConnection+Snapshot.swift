import Foundation

extension DaemonConnection {
    /// Fetches the first snapshot now, off the main thread, for the launch's
    /// prestart: the store's first resync takes it instead of asking again
    /// once the main thread is free. Events stay buffered meanwhile, and
    /// those past its barrier still apply, so it is as current as a later one.
    public func prefetchSnapshot() {
        guard prefetchedSnapshot == nil, let serial = ready?.serial else { return }
        // task-owner: one read per connection, taken (or dropped) by the first snapshot()
        prefetchedSnapshot = (serial, Task { try await self.fetchSnapshot() })
    }

    /// `list-workspaces` plus the sequence of the last event it supersedes.
    public func snapshot() async throws -> (tree: DaemonTree, barrier: UInt64) {
        let hadPrefetch = prefetchedSnapshot != nil
        if let prefetched = prefetchedSnapshot {
            prefetchedSnapshot = nil
            // A reconnect since then has another serial: its barrier would be wrong.
            if prefetched.serial == ready?.serial, let snapshot = try? await prefetched.fetch.value, prefetched.serial == ready?.serial {
                DaemonLaunchTimings.shared.mark(Self.snapshotSourceMark(hadPrefetch: true, usedPrefetch: true))
                return snapshot
            }
        }
        // The launch's marks keep a name's first time only: these are the first snapshot the store asked for
        // itself, which a cold launch's first tree may wait on (startup-matrix cut 2).
        DaemonLaunchTimings.shared.mark(Self.snapshotSourceMark(hadPrefetch: hadPrefetch, usedPrefetch: false))
        defer { DaemonLaunchTimings.shared.mark("daemon.store_snapshot.fetch_end") }
        return try await fetchSnapshot()
    }

    /// The launch mark naming where a store's snapshot came from: the prestart's prefetch, a prefetch it
    /// dropped (a reconnect since, or the prefetch failed) and fetched again, or a fetch with no prefetch.
    static func snapshotSourceMark(hadPrefetch: Bool, usedPrefetch: Bool) -> String {
        if usedPrefetch { return "daemon.store_snapshot.prefetched" }
        return hadPrefetch ? "daemon.store_snapshot.prefetch_dropped" : "daemon.store_snapshot.fetch_start"
    }

    private func fetchSnapshot() async throws -> (tree: DaemonTree, barrier: UInt64) {
        guard let ready else { throw DaemonError.notConnected }
        DaemonLaunchTimings.shared.mark("daemon.snapshot_start")
        defer { DaemonLaunchTimings.shared.mark("daemon.snapshot_end") }
        // Saved groups and personal state are their own reads, sent with
        // the tree in one round trip. Their changes emit `tree-changed` and
        // `personal-changed`, which trigger this snapshot again; an event
        // between the replies is past the tree's barrier, so it still applies.
        let savedGroups = identity?.supports(DaemonCapability.savedTabGroups.rawValue) == true
        let personal = identity?.supports(DaemonCapability.profiles.rawValue) == true
        var lines = [PipelinedLine(ListWorkspacesRequest())]
        if savedGroups { lines.append(PipelinedLine(ListSavedTabGroupsRequest())) }
        if personal { lines.append(PipelinedLine(ListPersonalRequest())) }
        var replies = await ready.transport.pipeline(lines, timeout: configuration.snapshotTimeout)[...]
        let response = try replies.removeFirst().get()
        var tree = try WireCoding.decodeResponse(DaemonTree.self, from: response.line)
        if savedGroups {
            let saved = try WireCoding.decodeResponse(ListSavedTabGroupsRequest.Response.self, from: replies.removeFirst().get().line)
            if tree.savedTabGroups.isEmpty {
                tree.savedTabGroups = saved.savedGroups
                tree.linkSavedTabGroups()
            }
        }
        if personal {
            tree.personal = try WireCoding.decodeResponse(ListPersonalRequest.Response.self, from: replies.removeFirst().get().line)
        }
        return (tree, DaemonEventEnvelope.sequence(serial: ready.serial, index: response.eventBarrier))
    }
}
