public import CmuxExtensionKit
public import CmuxSidebarProviderKit
public import Foundation

/// Pure value mapper from in-process provider-kit snapshot values to the
/// host-transport value types consumed by sidebar extensions, plus the
/// provider-text/section-title rendering used by the extension browser-stack
/// column and section views.
///
/// The app witness (`VerticalTabsSidebar`) still performs every live
/// `Workspace`/`TabManager`/panel read; it gathers those into provider-kit
/// value snapshots and per-workspace surface lists, then forwards them through
/// the closures here. This builder owns only the value-to-value field mapping,
/// so it carries no app-target state. Localization keeps resolving against the
/// main bundle exactly as before (`CmuxExtensionSidebarSelection.localizedText`
/// uses `bundle: .main`); the relative-date branch is resolved app-side and
/// passed in, keeping the app's `String(localized:)`-backed formatter on the
/// app target.
public struct ExtensionSidebarSnapshotBuilder: Sendable {
    /// Creates a stateless snapshot builder.
    public init() {}

    /// Maps a provider-kit snapshot to the frozen `CmuxSidebarSnapshot` wire
    /// value consumed by sidebar extension hosts. `surfaces` resolves the live
    /// per-workspace surface list app-side (it requires app-target panel/tab
    /// reads that cannot move into a package).
    public func cmuxSidebarSnapshot(
        from snapshot: CmuxSidebarProviderSnapshot,
        surfaces: (CmuxSidebarProviderWorkspace) -> [CmuxSidebarSurface]
    ) -> CmuxSidebarSnapshot {
        CmuxSidebarSnapshot(
            sequence: snapshot.sequence,
            windowID: snapshot.windowId,
            selectedWorkspaceID: snapshot.selectedWorkspaceId,
            workspaces: snapshot.workspaces.map { workspace in
                CmuxSidebarWorkspace(
                    id: workspace.id,
                    title: workspace.title,
                    detail: workspace.customDescription,
                    isPinned: workspace.isPinned,
                    rootPath: workspace.rootPath,
                    projectRootPath: workspace.projectRootPath,
                    gitBranch: workspace.branchSummary,
                    unreadCount: workspace.unreadCount,
                    latestNotification: workspace.latestNotificationText,
                    listeningPorts: workspace.listeningPorts,
                    pullRequestURLs: workspace.pullRequestURLs,
                    surfaces: surfaces(workspace)
                )
            }
        )
    }

    /// Builds a de-duplicated workspace-id keyed snapshot map for the given
    /// rows, resolving each workspace through `snapshot` (an app-side gather).
    public func workspaceSnapshotsById(
        for rows: [CmuxSidebarProviderRow],
        snapshot: (UUID) -> CmuxSidebarProviderWorkspace?
    ) -> [UUID: CmuxSidebarProviderWorkspace] {
        var snapshotsById: [UUID: CmuxSidebarProviderWorkspace] = [:]
        for row in rows where snapshotsById[row.workspaceId] == nil {
            snapshotsById[row.workspaceId] = snapshot(row.workspaceId)
        }
        return snapshotsById
    }

    /// Renders provider-row text. Plain text passes through, localized text is
    /// resolved against the main bundle, and relative-date text is rendered by
    /// `relativeDate` (the app-side `String(localized:)`-backed formatter).
    public func renderedText(
        _ text: CmuxSidebarProviderText?,
        now: Date,
        relativeDate: (Date, Date) -> String
    ) -> String? {
        guard let text else { return nil }
        switch text {
        case .plain(let value):
            return value
        case .localized(let localized):
            return CmuxExtensionSidebarSelection().localizedText(localized)
        case .relativeDate(let date, _):
            return relativeDate(date, now)
        }
    }

    /// Resolves a tree section's display title, preferring its localized title
    /// reference over the plain `title` fallback.
    public func treeSectionTitle(_ section: CmuxSidebarProviderTreeSection) -> String {
        if let titleText = section.titleText {
            return CmuxExtensionSidebarSelection().localizedText(titleText)
        }
        return section.title
    }
}
