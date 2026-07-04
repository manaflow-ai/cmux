import AppKit
import CmuxIssueInbox
import Combine
import Foundation

/// Runtime backing for one Issue Inbox surface.
@MainActor
final class IssueInboxPanel: Panel, ObservableObject {
    let id = UUID()
    let panelType: PanelType = .issueInbox
    let store: IssueInboxStore

    @Published private(set) var focusFlashToken: Int = 0

    var displayTitle: String {
        String(localized: "issueInbox.title", defaultValue: "Issue Inbox")
    }

    var displayIcon: String? { "tray.full" }

    init(store: IssueInboxStore = TerminalController.shared.issueInboxStore) {
        self.store = store
    }

    func close() {}

    func focus() {
        triggerFlash(reason: .navigation)
    }

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}
