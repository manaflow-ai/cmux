import Foundation

struct SessionWorkspaceLinkSnapshot: Codable, Equatable, Sendable {
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
}

extension SessionWorkspaceSnapshot {
    @MainActor
    mutating func captureLinksState(from workspace: Workspace) {
        let entries = workspace.linksState.entries
        links = entries.isEmpty ? nil : entries.map(SessionWorkspaceLinkSnapshot.init(entry:))
    }

    var restoredLinks: [WorkspaceCapturedLink] {
        (links ?? []).compactMap(\.linkEntry)
    }
}
