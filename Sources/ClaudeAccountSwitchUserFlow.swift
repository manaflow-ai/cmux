import AppKit
import Foundation

/// The one path the terminal context menu and the command palette take to move a Claude pane to
/// another account.
///
/// It asks first when Claude is mid-response, because the switch replaces the pane's process.
/// It then switches through ``Workspace/switchClaudeAccount(panelId:toAccountNamed:trigger:)``
/// and explains any outcome other than a resumed conversation with a
/// ``ClaudeAccountSwitchNotice``.
@MainActor
struct ClaudeAccountSwitchUserFlow {
    private let confirmStoppingResponse: @MainActor (_ accountName: String) -> Bool
    private let presentNotice: @MainActor (ClaudeAccountSwitchNotice) -> Void

    /// A flow that asks and reports with alerts.
    init() {
        self.init(
            confirmStoppingResponse: { Self.runConfirmationAlert(accountName: $0) },
            presentNotice: { Self.runNoticeAlert($0) }
        )
    }

    /// A flow that confirms and reports through the given closures instead of alerts.
    ///
    /// - Parameters:
    ///   - confirmStoppingResponse: Asked with the target account name while Claude is running;
    ///     `true` proceeds with the switch.
    ///   - presentNotice: Shown any notice the switch result maps to.
    init(
        confirmStoppingResponse: @escaping @MainActor (_ accountName: String) -> Bool,
        presentNotice: @escaping @MainActor (ClaudeAccountSwitchNotice) -> Void
    ) {
        self.confirmStoppingResponse = confirmStoppingResponse
        self.presentNotice = presentNotice
    }

    /// Switches the pane to `accountName` once the user agrees, then reports the outcome.
    ///
    /// - Returns: The switch result, or `nil` when the user cancelled and nothing changed.
    @discardableResult
    func run(workspace: Workspace, panelId: UUID, accountName: String) async -> ClaudeAccountSwitchResult? {
        if workspace.isClaudeResponseRunning(panelId: panelId),
           !confirmStoppingResponse(accountName) {
            return nil
        }
        let result = await workspace.switchClaudeAccount(
            panelId: panelId,
            toAccountNamed: accountName,
            trigger: .manual
        )
        if let notice = ClaudeAccountSwitchNotice(result: result, requestedAccountName: accountName) {
            presentNotice(notice)
        }
        return result
    }

    private static func runConfirmationAlert(accountName: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(
                localized: "dialog.claudeAccountSwitch.confirm.title",
                defaultValue: "Stop the current response and switch to %@?"
            ),
            accountName
        )
        alert.addButton(withTitle: String(
            localized: "dialog.claudeAccountSwitch.confirm.switch",
            defaultValue: "Switch"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func runNoticeAlert(_ notice: ClaudeAccountSwitchNotice) {
        let alert = NSAlert()
        alert.alertStyle = notice.reportsFailure ? .warning : .informational
        alert.messageText = notice.title
        alert.informativeText = notice.message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }
}
