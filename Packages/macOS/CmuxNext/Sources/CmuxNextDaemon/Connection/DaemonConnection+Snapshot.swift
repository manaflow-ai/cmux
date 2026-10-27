import Foundation

extension DaemonConnection {
    /// Fetches the first snapshot now, off the main thread, for the launch's
    /// prestart and the connection the startup attaches: the store's first resync takes it instead of asking again
    /// once the main thread is free. Events stay buffered meanwhile, and
    /// those past its barrier still apply, so it is as current as a later one.
    /// `onReceived` runs once the read answered (the launch's `daemon.snapshot_received`); a call while a prefetch
    /// runs does nothing.
    public func prefetchSnapshot(onReceived: (@Sendable () -> Void)? = nil) {
        guard prefetchedSnapshot == nil, let serial = ready?.serial else { return }
        // task-owner: one read per connection, taken (or dropped) by the first snapshot()
        prefetchedSnapshot = (serial, Task {
            let snapshot = try await self.fetchSnapshot()
            onReceived?()
            return snapshot
        })
    }

    /// `list-workspaces` plus the sequence of the last event it supersedes.
    public func snapshot() async throws -> (tree: DaemonTree, barrier: UInt64) {
        if let prefetched = prefetchedSnapshot {
            prefetchedSnapshot = nil
            // A reconnect since then has another serial: its barrier would be wrong.
            if prefetched.serial == ready?.serial, let snapshot = try? await prefetched.fetch.value, prefetched.serial == ready?.serial {
                return snapshot
            }
        }
        return try await fetchSnapshot()
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
        // The pipeline answers each line; a short answer is a broken reply, not a crash.
        let missing = DaemonError.malformedResponse("snapshot: fewer replies than requests")
        guard let treeReply = replies.popFirst() else { throw missing }
        let response = try treeReply.get()
        var tree = try WireCoding.decodeResponse(DaemonTree.self, from: response)
        if savedGroups {
            guard let savedReply = replies.popFirst() else { throw missing }
            let saved = try WireCoding.decodeResponse(ListSavedTabGroupsRequest.Response.self, from: savedReply.get())
            if tree.savedTabGroups.isEmpty {
                tree.savedTabGroups = saved.savedGroups
                tree.linkSavedTabGroups()
            }
        }
        if personal {
            guard let personalReply = replies.popFirst() else { throw missing }
            tree.personal = try WireCoding.decodeResponse(ListPersonalRequest.Response.self, from: personalReply.get())
        }
        return (tree, DaemonEventEnvelope.sequence(serial: ready.serial, index: response.eventBarrier))
    }
}
