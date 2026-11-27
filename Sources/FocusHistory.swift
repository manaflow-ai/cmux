import CmuxWorkspaces
import Foundation

// The focus-history value types (FocusHistoryEntry, FocusHistoryRecord,
// FocusHistoryMenuDirection/Position/Item/Snapshot) and the snapshot merge
// (FocusHistoryMenuSnapshot.recentlyFocused) live in CmuxWorkspaceNavigation.
// Only the localized menu formatting stays app-side.

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
