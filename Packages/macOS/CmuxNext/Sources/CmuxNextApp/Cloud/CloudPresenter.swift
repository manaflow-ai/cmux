import AppKit
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDesign
import os

/// Cloud results as toasts and Cloud questions as cmux dialogs, on the
/// active window (Lawrence 2026-10-07: results are toasts, never dialogs);
/// with no window a result is only logged and a question answers cancel.
enum CloudPresenter {
    static let resultToastID = "cloud-result"

    /// Shows a result as a toast: the title and the body's first line (the
    /// whole body when it is one short line). `copyable` text gets a Copy
    /// action that copies the whole body, and the toast stays 12 s.
    static func show(_ title: String, _ body: String, copyable: Bool = false, in window: NSWindow?) {
        guard let window else {
            Logger(subsystem: "com.cmuxterm.app.next", category: "cloud").info("cloud result with no window: \(title, privacy: .public)")
            return
        }
        let message = body.isEmpty ? title : CloudStrings.result(title, summary(body))
        let toast = CmuxToast(id: resultToastID, message: message, action: copyable ? CmuxToast.Action(title: CloudStrings.copy) : nil,
                              duration: .seconds(copyable ? 12 : 6))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = { copy(body) }
    }

    /// Shows a report as a toast: the title and `summary`, with a Copy
    /// details action that copies `details` (the raw report) and only on a
    /// click; the toast stays 12 s.
    static func show(_ title: String, summary: String, details: String, in window: NSWindow?) {
        guard let window else {
            Logger(subsystem: "com.cmuxterm.app.next", category: "cloud").info("cloud result with no window: \(title, privacy: .public)")
            return
        }
        let toast = CmuxToast(id: resultToastID, message: CloudStrings.result(title, summary),
                              action: CmuxToast.Action(title: CloudStrings.copyDetails), duration: .seconds(12))
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        handle.onAction = { copy(details) }
    }

    /// One short line: the body itself, else its first non-empty line with "…".
    static func summary(_ body: String, limit: Int = 120) -> String {
        let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return body }
        if lines.count == 1, first.count <= limit { return first }
        return String(first.prefix(limit)) + "…"
    }

    /// An error, copyable (the whole text goes to the clipboard on Copy).
    static func failure(_ error: any Error, in window: NSWindow?) {
        show(CloudStrings.failedTitle, CloudStrings.errorText(error), copyable: true, in: window)
    }

    /// The money confirmation of a machine create: only the person answers
    /// it (`DebugDialog.userOnly`), so automation can never approve a spend.
    static let createConfirmIdentifier = "cmux.dialog.cloud.createConfirm"

    /// Asks a yes/no question; `done(true)` only for a click on `button`.
    static func confirm(_ title: String, _ body: String, button: String, identifier: String = "cmux.dialog.cloud.confirm",
                        in window: NSWindow?, done: @escaping (Bool) -> Void) {
        let spec = CmuxDialogSpec(title: title, lines: [body],
                                  buttons: [.cancel(CloudStrings.cancel), CmuxDialogButton(id: "confirm", title: button, role: .default)],
                                  identifier: identifier)
        present(spec, in: window) { answer in done(answer?.button == "confirm") }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// nil when there is no window to ask in.
    private static func present(_ spec: CmuxDialogSpec, in window: NSWindow?, done: @escaping (CmuxDialogAnswer?) -> Void) {
        guard let window else { return done(nil) }
        CmuxDialogCenter.shared.present(spec, in: .window(window)) { done($0) }
    }

    /// Confirms provider setup for the tab’s resolved Cloud VM and reports failures in its window.
    @MainActor static func recoverCredentials(chat: String, request: AgentPaneCloudCredentialTransferRequest, services: AppServices) async -> Bool {
        guard services.cloud.isSignedIn,
              let userID = services.cloud.auth.user?.id,
              let (tab, _) = services.locateTab(chat),
              let daemon = try? services.machines.agentDaemon(forTab: tab),
              daemon.machineID == request.machineID,
              let session = services.machines.session(daemon.machineID),
              session.daemon.connection != nil else { return false }

        let teamID = services.cloud.auth.teamID
        guard let provider = CloudCredentialTransfer.Provider(rawValue: request.provider.rawValue) else { return false }
        let providerName = provider == .claude ? "Claude" : "Codex"
        let teamName = teamID.flatMap { id in services.cloud.auth.teams.first(where: { $0.id == id })?.displayName } ?? "Personal account"
        let body: String
        if provider == .claude {
            body = "cmux will run claude setup-token in a visible local terminal, then install the resulting one-year login on this owner VM for \(teamName)."
        } else {
            body = "cmux will start a fresh Codex device login in a visible local terminal for this VM. Codex refresh credentials are never copied between VMs; Codex requires a separate sign-in for each VM."
        }
        let spec = CmuxDialogSpec(
            title: "Set up \(providerName) on \(session.machine.title)?",
            lines: [body, "This replaces \(providerName)'s login for future launches on this VM. Existing sessions are unchanged."],
            buttons: [.cancel("Cancel"), CmuxDialogButton(id: "transfer", title: "Transfer and restart", role: .default)],
            identifier: "cmux.dialog.cloud.credentialRecovery")
        guard let window = services.windows.active?.window else { return false }
        let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
        guard answer.button == "transfer", !answer.isDismissal else { return false }

        let transfer = CloudCredentialTransfer(
            provider: provider, machineID: session.machineID, teamID: teamID,
            userID: userID,
            openTerminal: { [weak services] line in
                services?.inFrontPane { $0.newTerminalTab(typing: line + "\r") } ?? false
            })
        do {
            try await transfer.run(api: services.cloud.api,
                                   currentTeamID: { services.cloud.auth.teamID },
                                   currentUserID: { services.cloud.auth.user?.id },
                                   confirmed: true, refresh: true)
            return true
        } catch {
            CloudPresenter.failure(error, in: window)
            return false
        }
    }
}
