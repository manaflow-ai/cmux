import Foundation

struct FocusHistoryEntry: Equatable {
    let workspaceId: UUID
    let panelId: UUID?
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
    let isNavigable: Bool
}

struct FocusHistoryMenuSnapshot: Equatable {
    let items: [FocusHistoryMenuItem]
    let totalItemCount: Int
    let isLimited: Bool
}
