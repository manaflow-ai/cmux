import AppKit
import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign

/// The App's `ActionRegistry.confirmationPresenter`: the sheet a keyboard,
/// menu, palette, or context-menu run of a destructive action shows
/// before it runs. Scripted runs never get here (they pass `confirm`).
///
/// Closing a workspace asks only while one of its terminals runs a
/// foreground program (`process-info`); the other destructive actions
/// always ask. A target that does not resolve is not asked about: the
/// handler then refuses it with the usual typed reason.
enum DestructiveConfirmation {
    struct Prompt: Equatable {
        var title: String
        var body: String
        var button: String
    }

    static func install(_ services: AppServices) {
        services.registry.confirmationPresenter = { id, invocation, proceed in
            Task { @MainActor in
                guard let prompt = await prompt(for: id, invocation, services) else { return proceed() }
                present(prompt, in: services.windows.active?.window) { if $0 { proceed() } }
            }
        }
    }

    /// The question for this invocation, or nil to run without asking.
    static func prompt(for id: ActionID, _ invocation: ActionInvocation, _ services: AppServices) async -> Prompt? {
        let context = AppActionContext(services: services)
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
        case "workspaceGroup.delete", "workspaceGroup.closeWorkspaces":
            guard let group = try? context.group(invocation) else { return nil }
            let daemon = services.machines.daemons.first { $0.store.group(group.id) === group }
            let count = daemon?.store.workspaces.filter { $0.group == group.id }.count ?? 0
            let name = group.name.isEmpty ? ConfirmationStrings.unnamedGroup : group.name
            return id == "workspaceGroup.delete"
                ? Prompt(title: ConfirmationStrings.deleteGroupTitle(name), body: ConfirmationStrings.groupBody(count), button: ConfirmationStrings.delete)
                : Prompt(title: ConfirmationStrings.closeGroupWorkspacesTitle(name), body: ConfirmationStrings.groupBody(count),
                         button: ConfirmationStrings.close)
        case "browser.allowAgentWithExtensions":
            return AgentExtensionHandlers.prompt(invocation, context)
        case "space.delete":
            return RoomConfirmation.prompt(invocation, context)
        case "remote.install", "remote.forget":
            return await RemoteConfirmation.prompt(for: id, invocation, context)
        case "tabGroup.close":
            guard let (group, count) = tabGroup(invocation, context) else { return nil }
            let name = group.name.isEmpty ? ConfirmationStrings.unnamedGroup : group.name
            return Prompt(title: ConfirmationStrings.closeTabGroupTitle(name), body: ConfirmationStrings.tabGroupBody(count),
                          button: ConfirmationStrings.close)
        case "closeWorkspace":
            guard let workspace = context.scope(invocation).workspace,
                  let daemon = services.machines.daemon(forWorkspace: workspace.id) else { return nil }
            let programs = await runningPrograms(in: workspace, on: daemon)
            guard !programs.isEmpty else { return nil }
            return Prompt(title: ConfirmationStrings.closeWorkspaceTitle(workspace.displayName),
                          body: ConfirmationStrings.closeWorkspaceBody(programs.joined(separator: ", ")), button: ConfirmationStrings.close)
        default:
            return nil
        }
    }

    /// Foreground programs other than the shell, one per terminal, asked
    /// concurrently with a short deadline. A terminal that does not answer
    /// counts as idle rather than blocking the close.
    static func runningPrograms(in workspace: WorkspaceModel, on daemon: DaemonService) async -> [String] {
        guard let connection = daemon.connection else { return [] }
        let surfaces = workspace.screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == .pty && !$0.dead }.map(\.surface)
        return await withTaskGroup(of: String?.self) { group in
            for surface in surfaces {
                group.addTask {
                    try? await connection.request(TerminalProcessInfoRequest(surface: surface), timeout: .seconds(1)).runningProgram
                }
            }
            var programs: [String] = []
            for await program in group { if let program, !programs.contains(program) { programs.append(program) } }
            return programs.sorted()
        }
    }

    /// The targeted (or focused tab's) open tab group and its tab count,
    /// looked up without refusing.
    private static func tabGroup(_ invocation: ActionInvocation, _ context: AppActionContext) -> (TabGroupModel, Int)? {
        let explicit = [invocation.target, invocation["group"]?.targetValue].compactMap { $0 }.first { $0.kind == .tabGroup }?.id
        let id = explicit ?? context.scope(invocation).tabGroupID
        guard let id else { return nil }
        for daemon in context.services.machines.daemons {
            for pane in daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes) {
                if let group = pane.tabGroups.first(where: { $0.id.rawValue == id }) {
                    return (group, pane.tabs.filter { $0.tabGroup == group.id }.count)
                }
            }
        }
        return nil
    }

    /// A cmux dialog on `window` (Return confirms, Escape cancels). With no
    /// window there is nobody to ask, so the action does not run.
    static func present(_ prompt: Prompt, in window: NSWindow?, done: @escaping (Bool) -> Void) {
        guard let window else { return done(false) }
        CmuxDialogCenter.shared.present(spec(prompt), in: .window(window)) { done($0.button == confirmID) }
    }

    static let confirmID = "confirm"

    static func spec(_ prompt: Prompt) -> CmuxDialogSpec {
        CmuxDialogSpec(title: prompt.title, lines: [prompt.body],
                       buttons: [.cancel(ConfirmationStrings.cancel), CmuxDialogButton(id: confirmID, title: prompt.button, role: .default)],
                       identifier: "cmux.dialog.confirmation")
    }
}
