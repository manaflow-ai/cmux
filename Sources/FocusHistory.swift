import Foundation

struct FocusHistoryEntry: Equatable {
    let workspaceId: UUID
    let panelId: UUID?
}

struct FocusHistoryRecord: Equatable {
    let entry: FocusHistoryEntry
    var focusedAt: Date

    init(entry: FocusHistoryEntry, focusedAt: Date = Date()) {
        self.entry = entry
        self.focusedAt = focusedAt
    }
}

enum FocusHistoryMenuPosition: Equatable {
    case older
    case newer
}

enum FocusHistoryMenuDirection: Equatable {
    case back
    case forward
}

struct FocusHistoryMenuItem: Equatable {
    let historyIndex: Int
    let entry: FocusHistoryEntry
    let workspaceTitle: String
    let panelTitle: String?
    let position: FocusHistoryMenuPosition
    let focusedAt: Date
    let isNavigable: Bool
}

struct FocusHistoryMenuSnapshot: Equatable {
    let items: [FocusHistoryMenuItem]
    let totalItemCount: Int
    let isLimited: Bool
}

enum FocusHistoryMenuSnapshotBuilder {
    static func recentlyFocused(
        back: FocusHistoryMenuSnapshot,
        forward: FocusHistoryMenuSnapshot,
        maxItemCount: Int? = nil
    ) -> FocusHistoryMenuSnapshot {
        let items = (back.items + forward.items)
            .sorted { lhs, rhs in
                if lhs.focusedAt == rhs.focusedAt {
                    return lhs.historyIndex > rhs.historyIndex
                }
                return lhs.focusedAt > rhs.focusedAt
            }

        if let maxItemCount, maxItemCount >= 0, items.count > maxItemCount {
            return FocusHistoryMenuSnapshot(
                items: Array(items.prefix(maxItemCount)),
                totalItemCount: items.count,
                isLimited: true
            )
        }

        return FocusHistoryMenuSnapshot(
            items: items,
            totalItemCount: items.count,
            isLimited: false
        )
    }
}

enum FocusHistoryMenuFormatter {
    static func title(for item: FocusHistoryMenuItem) -> String {
        let fallbackWorkspaceTitle = String(localized: "menu.history.untitledWorkspace", defaultValue: "Untitled Workspace")
        let workspaceTitle = item.workspaceTitle.isEmpty ? fallbackWorkspaceTitle : item.workspaceTitle
        guard let panelTitle = item.panelTitle,
              !panelTitle.isEmpty,
              panelTitle != workspaceTitle else {
            return workspaceTitle
        }
        return String.localizedStringWithFormat(
            String(
                localized: "menu.history.focusedItemTitleFormat",
                defaultValue: "%1$@ - %2$@"
            ),
            workspaceTitle,
            panelTitle
        )
    }

    static func subtitle(for item: FocusHistoryMenuItem) -> String {
        let direction: String
        switch item.position {
        case .older:
            direction = String(localized: "menu.history.focusBack", defaultValue: "Focus Back")
        case .newer:
            direction = String(localized: "menu.history.focusForward", defaultValue: "Focus Forward")
        }

        let focused = String.localizedStringWithFormat(
            String(localized: "historyPane.focusedAtFormat", defaultValue: "Focused %@"),
            item.focusedAt.formatted(date: .omitted, time: .shortened)
        )
        return String.localizedStringWithFormat(
            String(localized: "menu.history.menuItemSubtitleFormat", defaultValue: "%1$@, %2$@"),
            direction,
            focused
        )
    }

    static func menuTitle(for item: FocusHistoryMenuItem) -> String {
        HistoryMenuLineFormatter.titleWithSubtitle(
            title: title(for: item),
            subtitle: subtitle(for: item)
        )
    }
}

enum HistoryMenuLineFormatter {
    static func titleWithSubtitle(title: String, subtitle: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSubtitle.isEmpty else { return trimmedTitle }
        guard !trimmedTitle.isEmpty else { return trimmedSubtitle }
        return "\(trimmedTitle)\n\(trimmedSubtitle)"
    }
}
