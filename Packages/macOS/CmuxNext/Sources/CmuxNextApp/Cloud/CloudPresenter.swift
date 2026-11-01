import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudCredentials
import CmuxNextDesign
import CmuxNextPages
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
    /// The confirmation of an environment build (a spend) or delete: only the person answers it.
    static let environmentConfirmIdentifier = "cmux.dialog.cloud.environmentConfirm"
    /// Credential installation always requires a real click; debug.dialog cannot approve it.
    static let credentialRecoveryIdentifier = "cmux.dialog.cloud.credentialRecovery"

    /// Asks a yes/no question; `done(true)` only for a click on `button`.
    static func confirm(_ title: String, _ body: String, button: String, identifier: String = "cmux.dialog.cloud.confirm",
                        in window: NSWindow?, done: @escaping (Bool) -> Void) {
        let spec = CmuxDialogSpec(title: title, lines: [body],
                                  buttons: [.cancel(CloudStrings.cancel), CmuxDialogButton(id: "confirm", title: button, role: .default)],
                                  identifier: identifier)
        present(spec, in: window) { answer in done(answer?.button == "confirm") }
    }

    /// Offers cmux Pro after a refusal Pro lifts, with the server's `message` (its
    /// localized reason) as the body; `closed(true)` only for the person's click on
    /// Upgrade. False when nothing was shown (no window); `closed` then never runs.
    static func offerPro(_ message: String?, in window: NSWindow?, closed: @escaping (Bool) -> Void) -> Bool {
        guard window != nil else { return false }
        confirm(CloudStrings.proRequiredTitle, message ?? CloudStrings.proRequiredBody, button: CloudStrings.proRequiredUpgrade,
                identifier: "cmux.dialog.cloud.proRequired", in: window, done: closed)
        return true
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
        guard AgentTabStore.cloudCredentialTransferIsAvailable(linkSource: services.cloud.configuration.linkSource,
                                                                isSignedIn: services.cloud.isSignedIn),
              let userID = services.cloud.auth.user?.id,
              let (tab, _) = services.locateTab(chat, onMachine: request.machineID),
              let daemon = try? services.machines.agentDaemon(forTab: tab),
              daemon.machineID == request.machineID,
              let session = services.machines.session(daemon.machineID),
              session.daemon.connection != nil else { return false }

        let teamID = services.cloud.auth.teamID
        guard let provider = CloudCredentialTransfer.Provider(rawValue: request.provider.rawValue) else { return false }
        let providerName = provider == .claude ? "Claude" : "Codex"
        let teamName = teamID.flatMap { id in services.cloud.auth.teams.first(where: { $0.id == id })?.displayName } ?? String(localized: "cloud.credentialRecovery.personalAccount", defaultValue: "Personal account", table: "CloudCredentialRecovery", bundle: .module)
        let body: String
        if provider == .claude {
            body = String(format: String(localized: "cloud.credentialRecovery.claudeDisclosure", defaultValue: "cmux will run claude setup-token in a visible local terminal, then install the resulting one-year login on this owner VM for %@.", table: "CloudCredentialRecovery", bundle: .module), teamName)
        } else {
            body = codexBrokerDisclosure
        }
        let spec = CmuxDialogSpec(
            title: String(format: String(localized: "cloud.credentialRecovery.title", defaultValue: "Set up %@ on %@?", table: "CloudCredentialRecovery", bundle: .module), providerName, session.machine.title),
            lines: [body, String(format: String(localized: "cloud.credentialRecovery.restartDisclosure", defaultValue: "This replaces %@'s login on this VM and restarts this chat before retrying its failed prompt.", table: "CloudCredentialRecovery", bundle: .module), providerName)],
            buttons: [.cancel(String(localized: "cloud.credentialRecovery.cancel", defaultValue: "Cancel", table: "CloudCredentialRecovery", bundle: .module)),
                      CmuxDialogButton(id: "transfer", title: String(localized: "cloud.credentialRecovery.transfer", defaultValue: "Transfer and restart", table: "CloudCredentialRecovery", bundle: .module), role: .default)],
            identifier: credentialRecoveryIdentifier)
        guard let window = services.windows.active?.window else { return false }
        let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
        guard answer.button == "transfer", !answer.isDismissal else { return false }
        // The confirmation and provider login are asynchronous. Revalidate the tab and account
        // after the gesture so a chat switch or account change cannot install credentials for the
        // stale request that opened the dialog.
        guard services.cloud.auth.user?.id == userID,
              services.cloud.auth.teamID == teamID,
              tab.agentSession?.session == request.sessionID,
              let (currentTab, _) = services.locateTab(chat, onMachine: request.machineID),
              currentTab === tab,
              (try? services.machines.agentDaemon(forTab: currentTab)) === daemon else { return false }

        // DEV and dogfood builds (cloud.startChat's own gate) let the creator's team machine take the
        // login here too; production keeps requiring an owner guest.
        let transfer = CloudCredentialTransfer(
            provider: provider, machineID: session.machineID, teamID: teamID,
            userID: userID,
            allowsCreatorTeamGuest: CloudStartChat.passesHarnessLoginHere,
            openTerminal: { [weak services] line in
                await services?.openLocalProviderLogin(line) ?? false
            })
        do {
            if provider == .codex {
                let scope = CloudCodexBrokerScope(userID: userID, teamID: teamID)
                try await services.cloud.codexBroker.run(
                    machineID: session.machineID, scope: scope, confirmed: true, forceRefresh: true,
                    presentDeviceCode: { [weak services, tabID = tab.id] prompt in
                        // The code dialog blocks only this chat's tab: the sign-in page opens in a cmux tab beside it.
                        let view = services?.madeAgentTabs?.existingView(tabID).flatMap { $0.window == nil || $0.isHiddenOrHasHiddenAncestor ? nil : $0 }
                        return await presentCodexDeviceCode(prompt, in: view.map(CmuxDialogScope.tab) ?? .window(window))
                    })
            } else {
                try await transfer.run(api: services.cloud.machineAPI,
                                       currentTeamID: { services.cloud.auth.teamID },
                                       currentUserID: { services.cloud.auth.user?.id },
                                       confirmed: true, refresh: true,
                                       callerOwnsVM: { [cloud = services.cloud, machineID = session.machineID] in try await cloud.callerOwnsVM(machineID) })
            }
            guard services.cloud.auth.user?.id == userID, services.cloud.auth.teamID == teamID,
                  let (currentTab, _) = services.locateTab(chat, onMachine: request.machineID),
                  currentTab.agentSession?.session == request.sessionID,
                  currentTab === tab,
                  (try? services.machines.agentDaemon(forTab: currentTab)) === daemon else { return false }
            let pinned = services.cloud.machineAPI.pinningTeam(teamID)
            guard try await restartCredentialSession(request.sessionID, creatorTeamGuest: transfer.allowsCreatorTeamGuest, exec: {
                try await pinned.exec(session.machineID, command: $0, timeoutMs: 300_000)
            }) else {
                CloudPresenter.show(String(localized: "cloud.credentialRecovery.installedTitle", defaultValue: "Credentials installed", table: "CloudCredentialRecovery", bundle: .module),
                                    String(localized: "cloud.credentialRecovery.restartDeferred", defaultValue: "The chat could not restart yet. Wait for any running turn to finish, then retry the prompt.", table: "CloudCredentialRecovery", bundle: .module), in: window)
                return false
            }
            return true
        } catch {
            CloudPresenter.failure(error, in: window)
            return false
        }
    }

    static let firstLoginIdentifier = "cmux.dialog.cloud.firstLogin"

    /// The one confirm before a `cloud.startChat` chat's first harness login (``CloudStartChat/passHarnessLogin(_:machine:)``):
    /// asked only when cmux holds no login for this account yet. False when cancelled or with no window.
    @MainActor static func confirmFirstLogin(provider: CloudCredentialTransfer.Provider, machine: String, services: AppServices) async -> Bool {
        guard provider == .claude, let window = services.windows.active?.window else { return false }
        let teamName = services.cloud.auth.teamID.flatMap { id in services.cloud.auth.teams.first(where: { $0.id == id })?.displayName }
            ?? String(localized: "cloud.credentialRecovery.personalAccount", defaultValue: "Personal account", table: "CloudCredentialRecovery", bundle: .module)
        let spec = CmuxDialogSpec(
            title: String(format: String(localized: "cloud.credentialRecovery.title", defaultValue: "Set up %@ on %@?", table: "CloudCredentialRecovery", bundle: .module), "Claude", machine),
            lines: [String(format: String(localized: "cloud.credentialRecovery.claudeDisclosure", defaultValue: "cmux will run claude setup-token in a visible local terminal, then install the resulting one-year login on this owner VM for %@.", table: "CloudCredentialRecovery", bundle: .module), teamName),
                    String(localized: "cloud.credentialRecovery.laterMachines", defaultValue: "Cloud machines you own later get this login with no prompt.", table: "CloudCredentialRecovery", bundle: .module)],
            buttons: [.cancel(String(localized: "cloud.credentialRecovery.cancel", defaultValue: "Cancel", table: "CloudCredentialRecovery", bundle: .module)),
                      CmuxDialogButton(id: "setUp", title: String(localized: "cloud.credentialRecovery.setUp", defaultValue: "Set Up", table: "CloudCredentialRecovery", bundle: .module), role: .default)],
            identifier: firstLoginIdentifier)
        let answer = await CmuxDialogCenter.shared.present(spec, in: .window(window))
        return answer.button == "setUp" && !answer.isDismissal
    }

    static let codexBrokerDisclosure = String(localized: "cloud.credentialRecovery.codexBroker", defaultValue: "cmux uses Codex sign-in on this Mac when needed; an existing broker login is refreshed without another sign-in. Only short-lived access moves to this owner VM. The refresh token stays on this Mac. Keep cmux running on this Mac to renew Codex access.", table: "CloudCodex", bundle: .module)

    static let codexDeviceCodeIdentifier = "cmux.dialog.cloud.codexDeviceCode"

    @MainActor static func presentCodexDeviceCode(_ prompt: CloudCodexLoginPrompt, in scope: CmuxDialogScope) async -> Bool {
        await presentCodexDeviceCode(prompt, in: scope, center: .shared,
                                     open: { LinkRouter.shared.open($0) }) // a cmux tab: browser.openSignInPagesInCmux
    }

    @MainActor static func presentCodexDeviceCode(_ prompt: CloudCodexLoginPrompt, in scope: CmuxDialogScope,
                                                 center: CmuxDialogCenter, open: (URL) -> Void) async -> Bool {
        let spec = codexDeviceDialogSpec(code: prompt.userCode)
        // wakeup-allow: every iteration suspends for a user answer; only Open sign-in repeats it, and cancellation dismisses the dialog.
        while !Task.isCancelled {
            let answers = AsyncStream.makeStream(of: CmuxDialogAnswer.self, bufferingPolicy: .bufferingNewest(1))
            let dialogID = center.present(spec, in: scope) { answer in
                answers.continuation.yield(answer)
                answers.continuation.finish()
            }
            defer { answers.continuation.finish(); center.dismiss(dialogID) }
            let answer = await withTaskCancellationHandler {
                var iterator = answers.stream.makeAsyncIterator()
                return await iterator.next()
            } onCancel: {
                // task-owner: one-shot cancellation hop dismisses this dialog; the continuation then releases it.
                Task { @MainActor in center.dismiss(dialogID) }
            }
            guard !Task.isCancelled, let answer, !answer.isDismissal else { return false }
            if answer.button == "open" { open(prompt.verificationURL) }
            else { return answer.button == "signedIn" }
        }
        return false
    }

    @MainActor static func codexDeviceDialogSpec(code: String) -> CmuxDialogSpec {
        CmuxDialogSpec(
            title: String(localized: "cloud.codexDevice.title", defaultValue: "Sign in to Codex", table: "CloudCodex", bundle: .module),
            lines: [
                String(format: String(localized: "cloud.codexDevice.code", defaultValue: "Use Codex sign-in on this Mac. Enter this one-time code: %@", table: "CloudCodex", bundle: .module), code),
                String(localized: "cloud.codexDevice.scope", defaultValue: "Only short-lived access moves to the VM; the refresh token stays on this Mac. Keep cmux running on this Mac to renew Codex access.", table: "CloudCodex", bundle: .module),
            ],
            buttons: [
                .cancel(String(localized: "cloud.codexDevice.cancel", defaultValue: "Cancel", table: "CloudCodex", bundle: .module)),
                CmuxDialogButton(id: "open", title: String(localized: "cloud.codexDevice.open", defaultValue: "Open sign-in", table: "CloudCodex", bundle: .module), role: .default),
                CmuxDialogButton(id: "signedIn", title: String(localized: "cloud.codexDevice.signedIn", defaultValue: "I signed in", table: "CloudCodex", bundle: .module), role: .normal),
            ], identifier: codexDeviceCodeIdentifier)
    }

    /// Use the same installed CLI and user as the credentials. Old/root-layout machines fail
    /// closed rather than restarting a different daemon. No provider output reaches the UI.
    /// `creatorTeamGuest`: the transfer's DEV creator allowance, so a team guest it installed on restarts too.
    @MainActor static func restartCredentialSession(_ sessionID: String, creatorTeamGuest: Bool = false,
                                                    exec: (String) async throws -> CloudExecResult) async throws -> Bool {
        let kinds = creatorTeamGuest ? "owner|team" : "owner"
        let command = """
            set -eu
            case "$(cat /etc/cmux/vm-kind 2>/dev/null)" in \(kinds)) ;; *) exit 1 ;; esac
            [ -x /home/cmux/.cmux/bin/cmux-tui ]
            if [ "$(id -u)" = 0 ]; then
              set -- setpriv --reuid=cmux --regid=cmux --init-groups
            else
              [ "$(id -un)" = cmux ]; set --
            fi
            "$@" env HOME=/home/cmux USER=cmux LOGNAME=cmux SHELL=/bin/bash TERM=xterm-256color \
              /home/cmux/.cmux/bin/cmux-tui acp --json session restart \(CloudStartSession.shellQuoted(sessionID))
            """
        let result = try await exec(command)
        guard result.exitCode == 0, result.stdout.utf8.count < 65_536,
              let reply = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              reply["failed"] as? Int == 0, reply["after_turn"] as? Int == 0,
              let restarted = reply["restarted"] as? Int, (0...1).contains(restarted) else { return false }
        // Zero means the process has already exited; the retry starts it with the new login.
        return true
    }
}
