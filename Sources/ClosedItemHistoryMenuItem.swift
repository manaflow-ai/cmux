import Foundation

struct ClosedItemHistoryMenuItem: Identifiable, Equatable {
    let id: UUID
    let kind: ClosedItemKind
    let title: String
    let detail: String
    let closedAt: Date
    /// True when this item's restored target is currently live (so it should be
    /// shown as already restored and skipped by "restore remaining" / undo).
    /// Computed at snapshot time from the in-memory restore map; defaults false.
    var isRestored: Bool = false

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
