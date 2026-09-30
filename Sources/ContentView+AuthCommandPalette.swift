import CmuxCloud
import CmuxCommandPalette
import AppKit
import Foundation

/// Describes where a command-palette action can run relative to a managed
/// Cloud workspace. The command materializer applies this once for every
/// contribution, keeping palette visibility aligned with the shared action
/// routing paths instead of duplicating gates in individual contributions.
enum CommandPaletteCloudCapability: Equatable {
    /// The action is valid for both local and Cloud workspaces.
    case shared
    /// The action needs a selected Cloud workspace and its current VM.
    case cloudOnly
    /// The action creates or reads a resource on this Mac's local filesystem
    /// or local browser stack and cannot target a Cloud workspace.
    case localOnly
}

extension ContentView {
    /// Returns the Cloud capability for every built-in command-palette action.
    /// Unknown and user-configured actions remain shared so custom actions keep
    /// their existing behavior unless they opt into their own routing checks.
    static func commandPaletteCloudCapability(for commandId: String) -> CommandPaletteCloudCapability {
        if commandId.hasPrefix("palette.terminalOpenDirectory.") {
            return .localOnly
        }

        switch commandId {
        case commandPaletteCloudForkCommandId,
             commandPaletteCloudSnapshotCommandId,
             commandPaletteCloudRestoreCommandId,
             commandPaletteCloudPromoteTemplateCommandId,
             commandPaletteCloudStatusCommandId,
             commandPaletteCloudPortsCommandId,
             commandPaletteCloudToolsCommandId,
             commandPaletteCloudHandoffCommandId:
            return .cloudOnly
        case "palette.newBrowserWorkspace",
             "palette.newAgentChat",
             "palette.newBrowserTab",
             "palette.newSimulatorPane",
             "palette.openFolder",
             "palette.openFolderInVSCodeInline",
             "palette.openWorkspacePullRequests",
             "palette.openDiffViewer",
             "palette.openDirectoryDiffViewer",
             "palette.findInDirectory",
             "palette.vscodeServeWebStop",
             "palette.vscodeServeWebRestart",
             "palette.browserSplitRight",
             "palette.browserSplitDown",
             "palette.terminalSplitBrowserRight",
             "palette.terminalSplitBrowserDown":
            return .localOnly
        default:
            return .shared
        }
    }

    /// Applies the capability classification to a palette context snapshot.
    /// Cloud-only commands are scoped to the selected VM; local-only commands
    /// are omitted while a Cloud workspace is selected.
    static func commandPaletteCloudCapabilityAllows(
        commandId: String,
        context: CommandPaletteContextSnapshot
    ) -> Bool {
        switch commandPaletteCloudCapability(for: commandId) {
        case .shared:
            return true
        case .cloudOnly:
            return context.bool(CommandPaletteContextKeys.workspaceIsCloud)
        case .localOnly:
            return !context.bool(CommandPaletteContextKeys.workspaceIsCloud)
        }
    }

    static let commandPaletteAuthSignInCommandId = "palette.auth.signIn"
    static let commandPaletteAuthSignOutCommandId = "palette.auth.signOut"
    static let commandPaletteAuthTeamPickerCommandId = "palette.auth.teamPicker"
    static let commandPaletteAuthTeamMembersCommandId = "palette.auth.teamMembers"

    static func commandPaletteAuthCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: commandPaletteAuthSignInCommandId,
                title: constant(String(localized: "command.auth.signIn.title", defaultValue: "Sign In")),
                subtitle: constant(String(localized: "command.auth.subtitle", defaultValue: "Account")),
                keywords: ["account", "auth", "authenticate", "authentication", "login", "log in", "signin", "sign in"],
                when: { context in
                    !context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteAuthSignOutCommandId,
                title: constant(String(localized: "command.auth.signOut.title", defaultValue: "Sign Out")),
                subtitle: constant(String(localized: "command.auth.subtitle", defaultValue: "Account")),
                keywords: ["account", "auth", "logout", "log out", "signout", "sign out"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteAuthTeamPickerCommandId,
                title: constant(String(localized: "command.auth.teamPicker.title", defaultValue: "Open Team Picker")),
                subtitle: constant(String(localized: "command.cloudVM.subtitle", defaultValue: "Cloud")),
                keywords: ["account", "auth", "team", "teams", "switch", "create"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteAuthTeamMembersCommandId,
                title: constant(String(localized: "command.auth.teamMembers.title", defaultValue: "Invite Team Members")),
                subtitle: constant(String(localized: "command.cloudVM.subtitle", defaultValue: "Cloud")),
                keywords: ["account", "auth", "team", "teams", "invite", "members", "roster", "seats"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.authSignedIn)
                        && !context.bool(CommandPaletteContextKeys.authWorking)
                }
            ),
        ]
    }

    func registerAuthCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.commandPaletteAuthSignInCommandId) {
#if DEBUG
            cmuxDebugLog("palette.auth.signIn.invoke")
#endif
            guard let auth = AppDelegate.shared?.auth else {
                NSSound.beep()
                return
            }
            auth.accountFlow.startSignIn()
        }
        registry.register(commandId: Self.commandPaletteAuthSignOutCommandId) {
#if DEBUG
            cmuxDebugLog("palette.auth.signOut.invoke")
#endif
            guard let auth = AppDelegate.shared?.auth else {
                NSSound.beep()
                return
            }
            Task { @MainActor in
                await auth.accountFlow.signOut()
            }
        }
        registry.register(commandId: Self.commandPaletteAuthTeamPickerCommandId) {
            _ = AppDelegate.shared?.openCloudTeamPicker(
                preferredWindow: tabManager.window,
                debugSource: "palette.auth.teamPicker"
            )
        }
        registry.register(commandId: Self.commandPaletteAuthTeamMembersCommandId) {
            guard let auth = AppDelegate.shared?.auth else {
                NSSound.beep()
                return
            }
            auth.accountFlow.showTeamInvite(preferredWindow: tabManager.window)
        }
    }
}

extension ContentView {
    static let commandPaletteCloudForkCommandId = "palette.cloud.fork"
    static let commandPaletteCloudSnapshotCommandId = "palette.cloud.snapshot"
    static let commandPaletteCloudRestoreCommandId = "palette.cloud.restore"
    static let commandPaletteCloudPromoteTemplateCommandId = "palette.cloud.promoteTemplate"
    static let commandPaletteCloudStatusCommandId = "palette.cloud.status"
    static let commandPaletteCloudPortsCommandId = "palette.cloud.ports"
    static let commandPaletteCloudToolsCommandId = "palette.cloud.tools"
    static let commandPaletteCloudHandoffCommandId = "palette.cloud.handoff"
    static let commandPaletteCloudNewMachineCommandId = "palette.cloud.newMachine"

    static func commandPaletteCloudCommandContributions(
        isAuthenticated: Bool? = nil
    ) -> [CommandPaletteCommandContribution] {
        // Feature-gated: hide every Cloud VM command from the palette when the
        // Cloud VM UI flag is off, matching the dropdown and shortcut gates.
        guard CloudMachinesFeature.isEnabled,
              isAuthenticated ?? (AppDelegate.shared?.auth?.accountFlow.isAuthenticated == true) else { return [] }
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }
        let subtitle = constant(String(localized: "command.cloudVM.subtitle", defaultValue: "Cloud"))
        return [
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudNewMachineCommandId,
                title: constant(String(localized: "command.cloudVM.newMachine.title", defaultValue: "New Cloud Machine\u{2026}")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "machine", "new", "create", "desktop", "base"]
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudForkCommandId,
                title: constant(String(localized: "command.cloudVM.fork.title", defaultValue: "Fork Current Cloud VM")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "fork", "clone", "branch"]
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudSnapshotCommandId,
                title: constant(String(localized: "command.cloudVM.snapshot.title", defaultValue: "Checkpoint Current Cloud VM")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "snapshot", "checkpoint", "save"]
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudRestoreCommandId,
                title: constant(String(localized: "command.cloudVM.restore.title", defaultValue: "Restore Cloud VM From Checkpoint")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "restore", "snapshot", "checkpoint"]
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudPromoteTemplateCommandId,
                title: constant(String(localized: "command.cloudVM.promoteTemplate.title", defaultValue: "Promote Current VM to Template")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "template", "promote", "snapshot"]
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudStatusCommandId,
                title: constant(String(localized: "command.cloudVM.status.title", defaultValue: "Show Cloud VM Status")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "status", "running", "paused"]
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudPortsCommandId,
                title: constant(String(localized: "command.cloudVM.ports.title", defaultValue: "Show Cloud VM Ports")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "ports", "preview", "localhost"]
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudToolsCommandId,
                title: constant(String(localized: "command.cloudVM.tools.title", defaultValue: "Inspect Cloud VM Tools")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "tools", "bootstrap", "zsh", "gh", "htop", "btop"]
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudHandoffCommandId,
                title: constant(String(localized: "command.cloudVM.handoff.title", defaultValue: "Show Agent Handoff")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "agent", "handoff", "copy"]
            ),
        ]
    }

    func registerCloudCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.commandPaletteCloudNewMachineCommandId) {
            _ = AppDelegate.shared?.performNewCloudMachineAction(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
                debugSource: "palette.cloud.newMachine"
            )
        }
        registry.register(commandId: Self.commandPaletteCloudForkCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(.fork, debugSource: "palette.cloud.fork")
        }
        registry.register(commandId: Self.commandPaletteCloudSnapshotCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(.snapshot, debugSource: "palette.cloud.snapshot")
        }
        registry.register(commandId: Self.commandPaletteCloudRestoreCommandId) {
            _ = AppDelegate.shared?.performCloudVMRestoreCommand(debugSource: "palette.cloud.restore")
        }
        registry.register(commandId: Self.commandPaletteCloudPromoteTemplateCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(.promoteTemplate, debugSource: "palette.cloud.promoteTemplate")
        }
        registry.register(commandId: Self.commandPaletteCloudStatusCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(.status, debugSource: "palette.cloud.status")
        }
        registry.register(commandId: Self.commandPaletteCloudPortsCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(.ports, debugSource: "palette.cloud.ports")
        }
        registry.register(commandId: Self.commandPaletteCloudToolsCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(.tools, debugSource: "palette.cloud.tools")
        }
        registry.register(commandId: Self.commandPaletteCloudHandoffCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(.handoff, debugSource: "palette.cloud.handoff")
        }
    }
}
