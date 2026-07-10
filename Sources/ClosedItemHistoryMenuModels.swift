import Foundation

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
}

struct ClosedItemHistoryMenuSnapshot {
    let items: [ClosedItemHistoryMenuItem]
    let totalItemCount: Int
    let isLimited: Bool
}

enum ClosedWindowRestoreValidation {
    static func hasUsableRestoredContent(
        snapshot: SessionWindowSnapshot,
        restoredPanelIdsByWorkspaceIndex: [[UUID: UUID]],
        hasLivePanels: Bool
    ) -> Bool {
        guard hasLivePanels else { return false }
        guard snapshot.hasRestorablePanels else { return true }
        return restoredPanelIdsByWorkspaceIndex.contains { !$0.isEmpty }
    }
}
