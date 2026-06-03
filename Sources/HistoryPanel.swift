import AppKit

/// A first-class workspace pane that browses the closed-item history (closed
/// terminals, browsers, panes, workspaces, and windows) and lets the user reopen
/// or forget any entry.
///
/// This is the History pane, distinct from the agent-session "Vault". Its content
/// is backed by the shared ``ClosedItemHistoryStore``; the panel itself holds no
/// per-workspace state.
@MainActor
final class HistoryPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .history

    @Published private(set) var focusFlashToken: Int = 0

    init() {
        self.id = UUID()
    }

    var displayTitle: String {
        String(localized: "history.pane.title", defaultValue: "History")
    }

    var displayIcon: String? { "clock.arrow.circlepath" }

    func close() {}

    func focus() {}

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}
