import Foundation

extension DaemonConnection {
    /// `list-workspaces` plus the sequence of the last event it supersedes.
    public func snapshot() async throws -> (tree: DaemonTree, barrier: UInt64) {
        guard let (transport, serial) = ready else { throw DaemonError.notConnected }
        DaemonLaunchTimings.shared.mark("daemon.snapshot_start")
        defer { DaemonLaunchTimings.shared.mark("daemon.snapshot_end") }
        // Saved groups and personal state are their own reads, sent with
        // the tree in one round trip. Their changes emit `tree-changed` and
        // `personal-changed`, which trigger this snapshot again; an event
        // between the replies is past the tree's barrier, so it still applies.
        let savedGroups = identity?.supports(DaemonCapabilities.shared.savedTabGroups) == true
        let personal = identity?.supports(DaemonCapabilities.shared.profiles) == true
        var lines = [PipelinedLine(ListWorkspacesRequest())]
        if savedGroups { lines.append(PipelinedLine(ListSavedTabGroupsRequest())) }
        if personal { lines.append(PipelinedLine(ListPersonalRequest())) }
        var replies = await transport.pipeline(lines, timeout: configuration.snapshotTimeout)[...]
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
        return (tree, DaemonEventEnvelope.sequence(serial: serial, index: response.eventBarrier))
    }
}
