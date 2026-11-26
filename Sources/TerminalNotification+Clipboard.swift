import AppKit
import Foundation

extension TerminalNotification {
    /// Plain text written to the pasteboard when a user copies this notification.
    ///
    /// Mirrors what the notification rows render: the workspace title (when known),
    /// the notification title, then the detail line. Detail follows the same rule
    /// the sidebar and menu bar use (`body`, falling back to `subtitle`), so the
    /// copied text matches the text on screen.
    func clipboardText(workspaceTitle: String? = nil) -> String {
        var lines: [String] = []
        if let workspaceTitle = workspaceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspaceTitle.isEmpty {
            lines.append(workspaceTitle)
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            lines.append(title)
        }
        let detail = (body.isEmpty ? subtitle : body).trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty, detail != title {
            lines.append(detail)
        }
        return lines.joined(separator: "\n")
    }
}

/// Single copy path shared by every notification surface (popover row, Notifications
/// pane). Entry points call this instead of touching `NSPasteboard` themselves.
enum TerminalNotificationClipboard {
    @MainActor
    @discardableResult
    static func copy(
        _ notification: TerminalNotification,
        workspaceTitle: String? = nil,
        pasteboard: NSPasteboard = .general
    ) -> String {
        let text = notification.clipboardText(workspaceTitle: workspaceTitle)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text
    }
}
