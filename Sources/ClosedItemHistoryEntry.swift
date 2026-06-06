enum ClosedItemHistoryEntry: Codable {
    case panel(ClosedPanelHistoryEntry)
    case workspace(ClosedWorkspaceHistoryEntry)
    case window(ClosedWindowHistoryEntry)
}
