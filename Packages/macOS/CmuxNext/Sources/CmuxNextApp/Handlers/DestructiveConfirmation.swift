import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextSettings
import CmuxNextUpdater
import os

/// The App's `ActionRegistry.confirmationPresenter`: the sheet a keyboard,
/// menu, palette, or context-menu run of a destructive action shows
/// before it runs. Scripted runs never get here (they pass `confirm`).
///
/// Closes never ask for themselves (Lawrence 2026-10-07: they run at once
/// and an undo toast offers them back; bulk closes, `WorkspaceBulkClose`).
/// Closing a workspace (its handler asks, WorkspaceCloseFlow), a group's workspaces or a space asks only while one of its terminals runs a
/// foreground program (`process-info`) and `app.warnBeforeClosingTab` is
/// on; a tab group follows the tab close rule (`TabCloseGuard`); those
/// questions have "Don't ask again". Forget Machine has an undo toast and
/// no question. The Cloud deletes, profile delete, Delete Chief, agent extension access,
/// remote install and Roll Back (it quits into the kept build) still ask.
/// A target that does not resolve is not asked about: the handler then
/// refuses it with the usual typed reason.
enum DestructiveConfirmation {
    struct Prompt: Equatable {
        var title: String
        var body: String
        var button: String
        /// The toggle "Don't ask again" turns off; nil shows no check box.
        var suppresses: [String]? = nil
        /// Return presses the button. False for a question that comes up a daemon read after the
        /// press (WorkspaceCloseFlow): typing on in the terminal must not confirm it.
        var returnConfirms = true
    }

    static func install(_ services: AppServices) {
        services.registry.confirmationPresenter = { id, invocation, proceed in
            // Close Workspace asks in its handler: its row stays put while the terminals answer and
            // while the question is up, and leaves at the press when nothing can ask (WorkspaceCloseFlow).
            if id == "closeWorkspace" {
                var run = invocation.confirmed()
                run.asksIfRunning = true
                services.registry.perform(id, invocation: run)
                return
            }
            Task { @MainActor in
                guard let prompt = await prompt(for: id, invocation, services) else { return proceed(false) }
                present(prompt, in: services.windows.active?.window, settings: services.settings) { if $0 { proceed(true) } }
            }
        }
    }

    /// The question for this invocation, or nil to run without asking.
    static func prompt(for id: ActionID, _ invocation: ActionInvocation, _ services: AppServices) async -> Prompt? {
        let context = AppActionContext(services: services)
        let warn = services.settings?.snapshot.warnBeforeClosingTab ?? CmuxConfigSnapshot.closeWarningFallback
        switch id {
        case "cloudKillMachine":
            return Prompt(title: CloudStrings.killMachineTitle, body: CloudStrings.killMachineBody, button: CloudStrings.kill)
        case "palette.cloud.deleteSnapshot":
            return Prompt(title: CloudStrings.deleteSnapshotTitle, body: CloudStrings.deleteSnapshotBody, button: CloudStrings.deleteSnapshot)
        case "cloudFileRemove":
            return Prompt(title: CloudStrings.removeFileTitle, body: CloudStrings.removeFileBody, button: CloudStrings.removeFile)
        case "cloudFirewallDelete":
            return Prompt(title: CloudStrings.deleteFirewallRuleTitle, body: CloudStrings.deleteFirewallRuleBody,
                          button: CloudStrings.deleteFirewallRule)
        case "workspaceGroup.closeWorkspaces":
            // No question of its own (an undo toast offers the workspaces back):
            // only a foreground program in them asks, as for Close Workspace.
            guard let group = try? context.group(invocation) else { return nil }
            return await WorkspaceBulkClose.prompt(WorkspaceGroupClose.members(of: group, context), warn: warn,
                                                   title: ConfirmationStrings.closeGroupWorkspacesTitle(group.name.isEmpty ? ConfirmationStrings.unnamedGroup : group.name))
        case let id where StashHandlers.workspaceActions.contains(id):
            // Save and Close of workspaces asks as their close does: only while a program runs.
            return await StashHandlers.prompt(id, invocation, context, warn: warn)
        case let id where WorkspaceBulkClose.ids.contains(id):
            return await WorkspaceBulkClose.prompt(id, invocation, context, warn: warn)
        case "browserProfile.delete":
            return await BrowserProfileDeletePrompt.prompt(invocation, context)
        case "browser.allowAgentWithExtensions":
            return AgentExtensionHandlers.prompt(invocation, context)
        case "space.delete":
            return await RoomConfirmation.prompt(invocation, context)
        case "space.clearDefaults":
            return await RoomConfirmation.clearDefaultsPrompt(invocation, context)
        case "remote.install":
            return await RemoteConfirmation.prompt(for: id, invocation, context)
        case "updates.rollback": // palette, menu and the pulled-build banner's Roll Back
            return Prompt(title: UpdateDropBack.confirmation.title, body: UpdateDropBack.confirmation.body, button: UpdateDropBack.confirmation.button)
        case "tabGroup.close":
            // The rule of every tab close (TabCloseGuard): the undo toast
            // brings the group back, so only work in progress asks.
            guard let (tabs, daemon) = tabGroup(invocation, context) else { return nil }
            return await TabCloseGuard.prompt(closing: tabs, on: daemon, services: services)
        case "taskManager.killProcess":
            // A process Kill Process refuses is not asked about: the handler says why.
            let key = services.taskManager.process(invocation["process"]?.stringValue)
            guard let key, services.taskManager.refusal(for: key) == nil else { return nil }
            let question = services.taskManager.prompt(for: key)
            return Prompt(title: question.title, body: question.body, button: question.button)
        case "home.deleteChief":
            // A Chief not listed (or the default one) is refused by the action with its reason.
            guard let id = invocation["chief"]?.stringValue, let chief = services.home.deletableChief(id: id) else { return nil }
            return Prompt(title: HomeStrings.deleteChiefTitle(chief.name), body: HomeStrings.deleteChiefBody,
                          button: HomeStrings.deleteChiefButton, returnConfirms: false)
        case "home.leaveConversation":
            // The group's name in the question; a conversation not listed is refused by the action.
            let id = invocation["conversation"]?.stringValue.map { ConversationID($0) } ?? AppActions.shownPage(services)?.shown
            guard let id, let info = services.home.groupActions.info(id), info.isGroup else { return nil }
            let prompt = info.leavePrompt
            return Prompt(title: prompt.title, body: prompt.body, button: prompt.button)
        default:
            return nil
        }
    }

    /// Foreground programs other than the shell, one per terminal, asked
    /// concurrently with a short deadline. A terminal that does not answer
    /// counts as idle rather than blocking the close.
    static func runningPrograms(in workspace: WorkspaceModel, on daemon: DaemonService) async -> [String] {
        await runningPrograms(of: workspace.screens.flatMap(\.panes).flatMap(\.tabs), on: daemon)
    }

    /// The same for `tabs` (their live terminals only).
    static func runningPrograms(of tabs: [TabModel], on daemon: DaemonService) async -> [String] {
        await runningPrograms(bySurface: tabs, on: daemon).programNames
    }

    /// The same, per asked terminal: each live terminal's foreground program,
    /// or nil when it runs none (or did not answer). One gesture asks once and
    /// passes this on (a close's question, then its undo toast decision).
    static func runningPrograms(bySurface tabs: [TabModel], on daemon: DaemonService) async -> RunningPrograms {
        let surfaces = tabs.filter { $0.kind == .pty && !$0.dead }.map(\.surface)
        guard let connection = daemon.connection, !surfaces.isEmpty else { return [:] }
        return await withTaskGroup(of: (SurfaceID, String?).self) { group in
            for surface in surfaces {
                group.addTask {
                    (surface, try? await connection.request(TerminalProcessInfoRequest(surface: surface), timeout: .seconds(1)).runningProgram)
                }
            }
            var programs: RunningPrograms = [:]
            for await (surface, program) in group { programs[surface] = .some(program) }
            return programs
        }
    }

    /// The targeted (or focused tab's) open tab group's tabs and their
    /// daemon, looked up without refusing.
    private static func tabGroup(_ invocation: ActionInvocation, _ context: AppActionContext) -> ([TabModel], DaemonService)? {
        let explicit = [invocation.target, invocation["group"]?.targetValue].compactMap { $0 }.first { $0.kind == .tabGroup }?.id
        let id = explicit ?? context.scope(invocation).tabGroupID
        guard let id else { return nil }
        for daemon in context.services.machines.daemons {
            for pane in daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes) {
                if let group = pane.tabGroups.first(where: { $0.id.rawValue == id }) {
                    return (pane.tabs.filter { $0.tabGroup == group.id }, daemon)
                }
            }
        }
        return nil
    }

    /// A cmux dialog on `window` (Return confirms, Escape cancels). With no
    /// window there is nobody to ask, so the action does not run.
    /// A confirmed answer with "Don't ask again" checked turns the prompt's toggle off.
    static func present(_ prompt: Prompt, in window: NSWindow?, settings: SettingsController? = nil,
                        done: @escaping (Bool) -> Void) {
        guard let window else { return done(false) }
        CmuxDialogCenter.shared.present(spec(prompt), in: .window(window)) { answer in
            let confirmed = answer.button == confirmID
            if confirmed, answer.values[suppressID]?.bool == true, let path = prompt.suppresses { turnOff(path, settings) }
            done(confirmed)
        }
    }

    static let confirmID = "confirm"
    static let suppressID = "dont-ask-again"

    static func spec(_ prompt: Prompt) -> CmuxDialogSpec {
        CmuxDialogSpec(title: prompt.title, lines: [prompt.body],
                       fields: prompt.suppresses == nil ? [] : [.check(id: suppressID, title: QuitStrings.dontAskAgain, on: false)],
                       buttons: [.cancel(ConfirmationStrings.cancel), CmuxDialogButton(id: confirmID, title: prompt.button, role: prompt.returnConfirms ? .default : .destructive)],
                       identifier: "cmux.dialog.confirmation")
    }

    private static func turnOff(_ path: [String], _ settings: SettingsController?) {
        guard let settings, let descriptor = SettingsSchema.descriptor(for: path) else { return }
        Task { @MainActor in
            do { try await settings.setSetting(descriptor, to: .bool(false), by: .user) } catch {
                Logger(subsystem: "com.cmuxterm.app.next", category: "app.close")
                    .error("close warning write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
