import CmuxWorkspaces
import Foundation

/// One row in the recently-closed history menu: the display title, a secondary
/// detail (the closed item's kind), and the timestamp it closed at. The static
/// factory members build a menu item from a persisted ``ClosedItemHistoryRecord``
/// and live on this type because it is the value they produce (CONVENTIONS §9).
struct ClosedItemHistoryMenuItem: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let closedAt: Date

    var menuSubtitle: String {
        let closed = String(
            format: String(localized: "historyPane.closedAtFormat", defaultValue: "Closed %@"),
            closedAt.formatted(date: .omitted, time: .shortened)
        )
        return String(
            format: String(localized: "menu.history.menuItemSubtitleFormat", defaultValue: "%1$@, %2$@"),
            detail,
            closed
        )
    }

    var menuTitle: String {
        HistoryMenuLineFormatter.titleWithSubtitle(
            title: title,
            subtitle: menuSubtitle
        )
    }

    static func menuItem(for record: ClosedItemHistoryRecord) -> ClosedItemHistoryMenuItem {
        switch record.entry {
        case .panel(let entry):
            return ClosedItemHistoryMenuItem(
                id: record.id,
                title: title(for: entry.snapshot),
                detail: String(localized: "menu.history.recentlyClosed.kind.tab", defaultValue: "Tab"),
                closedAt: record.closedAt
            )
        case .workspace(let entry):
            return ClosedItemHistoryMenuItem(
                id: record.id,
                title: title(for: entry.snapshot),
                detail: String(localized: "menu.history.recentlyClosed.kind.workspace", defaultValue: "Workspace"),
                closedAt: record.closedAt
            )
        case .window(let entry):
            return ClosedItemHistoryMenuItem(
                id: record.id,
                title: String(localized: "menu.history.recentlyClosed.kind.window", defaultValue: "Window"),
                detail: windowWorkspaceCountLabel(entry.snapshot.tabManager.workspaces.count),
                closedAt: record.closedAt
            )
        }
    }

    private static func title(for snapshot: SessionPanelSnapshot) -> String {
        let candidates = [
            snapshot.customTitle,
            snapshot.title,
            // String-only path math — NOT URL(fileURLWithPath:), which lstat()s
            // the path to infer directory-ness. These snapshots can hold REMOTE
            // working directories (closed remote-tmux tabs); stat'ing one on the
            // main thread blocks on the autofs automounter (e.g. /home/…) for
            // hundreds of ms per record, and this runs inside the App commands
            // body on every menu rebuild.
            snapshot.directory.map { ($0 as NSString).lastPathComponent }
        ]
        if let title = candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return title
        }

        switch snapshot.type {
        case .terminal:
            return String(localized: "menu.history.recentlyClosed.panel.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "menu.history.recentlyClosed.panel.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "menu.history.recentlyClosed.panel.markdown", defaultValue: "Markdown")
        case .filePreview:
            return String(localized: "menu.history.recentlyClosed.panel.filePreview", defaultValue: "File Preview")
        case .rightSidebarTool:
            if let mode = snapshot.rightSidebarTool?.mode {
                return mode.label
            }
            return String(localized: "menu.history.recentlyClosed.panel.tool", defaultValue: "Tool")
        case .agentSession:
            return String(localized: "menu.history.recentlyClosed.panel.agentSession", defaultValue: "Agent")
        case .project:
            return String(localized: "menu.history.recentlyClosed.panel.project", defaultValue: "Project")
        case .extensionBrowser:
            return String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
        case .customSidebar:
            return String(localized: "menu.history.recentlyClosed.panel.customSidebar", defaultValue: "Custom Sidebar")
        }
    }

    private static func title(for snapshot: SessionWorkspaceSnapshot) -> String {
        let candidates = [
            snapshot.customTitle,
            Optional(snapshot.processTitle),
            directoryTitleCandidate(snapshot.currentDirectory)
        ]
        if let title = candidates.compactMap({ normalizedTitleCandidate($0) })
            .first(where: { !$0.isEmpty }) {
            return title
        }
        return String(localized: "menu.history.untitledWorkspace", defaultValue: "Untitled Workspace")
    }

    private static func directoryTitleCandidate(_ directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        // String-only path math — see title(for:): URL(fileURLWithPath:) would
        // lstat() a possibly-remote path on the main thread.
        return (trimmed as NSString).lastPathComponent
    }

    private static func normalizedTitleCandidate(_ candidate: String?) -> String? {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        return trimmed
    }

    private static func windowWorkspaceCountLabel(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "menu.history.recentlyClosed.window.workspaceCount.one", defaultValue: "1 workspace")
        }
        return String.localizedStringWithFormat(
            String(
                localized: "menu.history.recentlyClosed.window.workspaceCount.other",
                defaultValue: "%d workspaces"
            ),
            count
        )
    }
}

/// A bounded view of the recently-closed history for menu rendering: the items
/// to show, the total count before any limit, and whether the list was limited.
struct ClosedItemHistoryMenuSnapshot {
    let items: [ClosedItemHistoryMenuItem]
    let totalItemCount: Int
    let isLimited: Bool
}
