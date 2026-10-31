import AppKit
import Foundation

/// The one path the terminal context menu and the command palette take to move a Claude pane to
/// another account.
///
/// It asks first when Claude is mid-response, because the switch replaces the pane's process.
/// It then switches through ``Workspace/switchClaudeAccount(panelId:toAccountNamed:trigger:)``
/// and explains any outcome other than a resumed conversation with a
/// ``ClaudeAccountSwitchNotice``. When the resume command was never typed but the respawned pane
/// is still there, the notice offers to type it.
@MainActor
struct ClaudeAccountSwitchUserFlow {
    /// Types a switch's resume input into the respawned panel; `true` when it reached the terminal.
    typealias ResumeInputTyper = @MainActor (
        _ input: String,
        _ workspace: Workspace,
        _ panel: TerminalPanel,
        _ panelId: UUID
    ) -> Bool

    private let confirmStoppingResponse: @MainActor (_ accountName: String) -> Bool
    private let presentNotice: @MainActor (
        ClaudeAccountSwitchNotice,
        _ typeResumeCommand: (@MainActor () -> Bool)?
    ) -> Void
    private let typeResumeInput: ResumeInputTyper

    /// A flow that asks and reports with alerts and types through the workspace.
    init() {
        self.init(
            confirmStoppingResponse: { Self.runConfirmationAlert(accountName: $0) },
            presentNotice: { Self.runNoticeAlert($0, typeResumeCommand: $1) },
            typeResumeInput: { input, workspace, panel, panelId in
                workspace.typeClaudeAccountSwitchResumeInput(input, into: panel, panelId: panelId)
            }
        )
    }

    /// A flow that confirms, reports and types through the given closures instead of alerts.
    ///
    /// - Parameters:
    ///   - confirmStoppingResponse: Asked with the target account name while Claude is running;
    ///     `true` proceeds with the switch.
    ///   - presentNotice: Shown any notice the switch result maps to, with the Type Resume
    ///     Command action when the notice offers one.
    ///   - typeResumeInput: Runs that action: types the built resume input into the panel.
    init(
        confirmStoppingResponse: @escaping @MainActor (_ accountName: String) -> Bool,
        presentNotice: @escaping @MainActor (
            ClaudeAccountSwitchNotice,
            _ typeResumeCommand: (@MainActor () -> Bool)?
        ) -> Void,
        typeResumeInput: @escaping ResumeInputTyper
    ) {
        self.confirmStoppingResponse = confirmStoppingResponse
        self.presentNotice = presentNotice
        self.typeResumeInput = typeResumeInput
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
        report(result, accountName: accountName, workspace: workspace, panelId: panelId)
        return result
    }

    /// Presents the notice `result` maps to, if any. A switch whose resume was never typed into a
    /// pane that still exists gets the action that types it into that same pane.
    func report(
        _ result: ClaudeAccountSwitchResult,
        accountName: String,
        workspace: Workspace,
        panelId: UUID
    ) {
        guard let notice = ClaudeAccountSwitchNotice(result: result, requestedAccountName: accountName) else {
            return
        }
        var typeResumeCommand: (@MainActor () -> Bool)?
        if notice.offersTypingResumeCommand,
           case .switchedWithoutResume(_, _, let manualResume) = result,
           let panel = workspace.terminalPanel(for: panelId) {
            let typeResumeInput = self.typeResumeInput
            // Bound to the respawned panel: a pane closed or respawned again since gets nothing.
            typeResumeCommand = { [weak workspace, weak panel] in
                guard let workspace, let panel else { return false }
                return typeResumeInput(manualResume.typedInput, workspace, panel, panelId)
            }
        }
        presentNotice(notice, typeResumeCommand)
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

    private static func runNoticeAlert(
        _ notice: ClaudeAccountSwitchNotice,
        typeResumeCommand: (@MainActor () -> Bool)?
    ) {
        let alert = NSAlert()
        alert.alertStyle = notice.reportsFailure ? .warning : .informational
        alert.messageText = notice.title
        alert.informativeText = notice.message
        guard let typeResumeCommand else {
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            alert.runModal()
            return
        }
        alert.addButton(withTitle: String(
            localized: "dialog.claudeAccountSwitch.typeResumeCommand",
            defaultValue: "Type Resume Command"
        ))
        // Escape closes the alert, as it does every alert with a Cancel button.
        alert.addButton(withTitle: String(localized: "common.close", defaultValue: "Close")).keyEquivalent = "\u{1b}"
        if alert.runModal() == .alertFirstButtonReturn, !typeResumeCommand() {
            NSSound.beep()
        }
    }
}
