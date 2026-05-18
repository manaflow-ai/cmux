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

enum FocusHistoryMenuFormatter {
    static func title(for item: FocusHistoryMenuItem) -> String {
        let fallbackWorkspaceTitle = String(localized: "menu.history.untitledWorkspace", defaultValue: "Untitled Workspace")
        let workspaceTitle = item.workspaceTitle.isEmpty ? fallbackWorkspaceTitle : item.workspaceTitle
        guard let panelTitle = item.panelTitle,
              !panelTitle.isEmpty,
              panelTitle != workspaceTitle else {
            return workspaceTitle
        }
        return "\(workspaceTitle) - \(panelTitle)"
    }
}
