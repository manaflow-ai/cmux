/// A persisted Links array that decodes at most the supported retention cap.
struct SessionWorkspaceLinksSnapshotCollection: Codable, Sendable {
    let snapshots: [SessionWorkspaceLinkSnapshot]

    init(_ snapshots: [SessionWorkspaceLinkSnapshot]) {
        self.snapshots = Array(
            snapshots.prefix(WorkspaceLinksIngestConfiguration.maximumRetentionLimit)
        )
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var snapshots: [SessionWorkspaceLinkSnapshot] = []
        snapshots.reserveCapacity(min(
            container.count ?? 0,
            WorkspaceLinksIngestConfiguration.maximumRetentionLimit
        ))
        while !container.isAtEnd,
              snapshots.count < WorkspaceLinksIngestConfiguration.maximumRetentionLimit {
            snapshots.append(try container.decode(SessionWorkspaceLinkSnapshot.self))
        }
        self.snapshots = snapshots
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for snapshot in snapshots.prefix(WorkspaceLinksIngestConfiguration.maximumRetentionLimit) {
            try container.encode(snapshot)
        }
    }
}
