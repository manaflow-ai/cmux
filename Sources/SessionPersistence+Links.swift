import Foundation

struct SessionWorkspaceLinkSnapshot: Codable, Equatable, Sendable {
    private static let maximumURLUTF8Bytes = 4_096
    private static let maximumHostUTF8Bytes = 512
    private static let maximumSourceTitleUTF8Bytes = 512
    private static let maximumFetchedTitleUTF8Bytes = 2_048
    private static let maximumOriginUTF8Bytes = 64

    var id: UUID
    var url: String
    var hostKey: String?
    var firstSeen: Date
    var lastSeen: Date
    var count: Int
    var sourcePanelId: UUID?
    var sourceSurfaceTitle: String?
    var origin: String
    var fetchedTitle: String?

    init(entry: WorkspaceCapturedLink) {
        self.id = entry.id
        self.url = entry.url
        self.hostKey = entry.hostKey
        self.firstSeen = entry.firstSeen
        self.lastSeen = entry.lastSeen
        self.count = entry.count
        self.sourcePanelId = entry.sourcePanelId
        self.sourceSurfaceTitle = entry.sourceSurfaceTitle
        self.origin = entry.origin.rawValue
        self.fetchedTitle = entry.fetchedTitle
    }

    var linkEntry: WorkspaceCapturedLink? {
        guard Self.isWithinUTF8Limit(url, maximumBytes: Self.maximumURLUTF8Bytes),
              Self.isWithinUTF8Limit(hostKey, maximumBytes: Self.maximumHostUTF8Bytes),
              Self.isWithinUTF8Limit(
                  sourceSurfaceTitle,
                  maximumBytes: Self.maximumSourceTitleUTF8Bytes
              ),
              Self.isWithinUTF8Limit(
                  fetchedTitle,
                  maximumBytes: Self.maximumFetchedTitleUTF8Bytes
              ),
              Self.isWithinUTF8Limit(origin, maximumBytes: Self.maximumOriginUTF8Bytes) else {
            return nil
        }
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty else { return nil }
        return WorkspaceCapturedLink(
            id: id,
            url: normalizedURL,
            hostKey: hostKey,
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            count: max(1, count),
            sourcePanelId: sourcePanelId,
            sourceSurfaceTitle: sourceSurfaceTitle,
            origin: WorkspaceCapturedLinkOrigin(rawValue: origin) ?? .detected,
            fetchedTitle: fetchedTitle
        )
    }

    private static func isWithinUTF8Limit(
        _ value: String?,
        maximumBytes: Int
    ) -> Bool {
        guard let value else { return true }
        return value.utf8.prefix(maximumBytes + 1).count <= maximumBytes
    }
}

extension SessionWorkspaceSnapshot {
    @MainActor
    mutating func captureLinksState(from workspace: Workspace) {
        let entries = workspace.linksState.entries
        links = entries.isEmpty
            ? nil
            : SessionWorkspaceLinksSnapshotCollection(
                entries.map(SessionWorkspaceLinkSnapshot.init(entry:))
            )
    }

    func restoredLinks(limit: Int) -> [WorkspaceCapturedLink] {
        let cap = WorkspaceLinksIngestConfiguration.clampedRetentionLimit(limit)
        return (links?.snapshots ?? []).prefix(cap).compactMap(\.linkEntry)
    }
}
