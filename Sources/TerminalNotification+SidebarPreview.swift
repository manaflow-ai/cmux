import Foundation

extension TerminalNotification {
    func sidebarPreviewText(forTabId tabId: UUID) -> String? {
        // Workspace notices have no pane activity to replace their preview.
        // Hide them once read, including notices restored from older sessions.
        if isRead && matches(tabId: tabId, surfaceId: nil) {
            return nil
        }
        let text = body.isEmpty ? title : body
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
