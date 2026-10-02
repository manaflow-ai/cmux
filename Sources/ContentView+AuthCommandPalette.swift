import CmuxCloud
import CmuxCommandPalette
import AppKit
import Foundation

extension ContentView {
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
    static let commandPaletteCloudAvailabilityInfoCommandId = "palette.cloud.availabilityInfo"
    static let commandPaletteCloudForkCommandId = "palette.cloud.fork"
    static let commandPaletteCloudSnapshotCommandId = "palette.cloud.snapshot"
    static let commandPaletteCloudRestoreCommandId = "palette.cloud.restore"
    static let commandPaletteCloudPromoteTemplateCommandId = "palette.cloud.promoteTemplate"
    static let commandPaletteCloudStatusCommandId = "palette.cloud.status"
    static let commandPaletteCloudPortsCommandId = "palette.cloud.ports"
    static let commandPaletteCloudToolsCommandId = "palette.cloud.tools"
    static let commandPaletteCloudHandoffCommandId = "palette.cloud.handoff"
    static let commandPaletteCloudNewMachineCommandId = "palette.cloud.newMachine"

    /// Returns Cloud VM commands when the Cloud feature and account are ready.
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
        func capabilityGate(_ key: CommandPaletteContextKeys) -> (CommandPaletteContextSnapshot) -> Bool {
            { context in
                !context.bool(CommandPaletteContextKeys.cloudVMCapabilitiesKnown)
                    || context.bool(key)
            }
        }
        let subtitle = constant(String(localized: "command.cloudVM.subtitle", defaultValue: "Cloud"))
        return [
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudNewMachineCommandId,
                title: constant(String(localized: "command.cloudVM.newMachine.title", defaultValue: "New Cloud Machine…")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "machine", "new", "create", "desktop", "base"]
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudForkCommandId,
                title: constant(String(localized: "command.cloudVM.fork.title", defaultValue: "Fork Current Cloud VM")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "fork", "clone", "branch"],
                when: capabilityGate(.cloudVMSupportsFork)
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudSnapshotCommandId,
                title: constant(String(localized: "command.cloudVM.snapshot.title", defaultValue: "Checkpoint Current Cloud VM")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "snapshot", "checkpoint", "save"],
                when: capabilityGate(.cloudVMSupportsSnapshot)
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudRestoreCommandId,
                title: constant(String(localized: "command.cloudVM.restore.title", defaultValue: "Restore Cloud VM From Checkpoint")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "restore", "snapshot", "checkpoint"],
                when: capabilityGate(.cloudVMSupportsRestore)
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudPromoteTemplateCommandId,
                title: constant(String(localized: "command.cloudVM.promoteTemplate.title", defaultValue: "Promote Current VM to Template")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "template", "promote", "snapshot"],
                when: capabilityGate(.cloudVMSupportsSnapshot)
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
                keywords: ["cloud", "vm", "ports", "preview", "localhost"],
                when: capabilityGate(.cloudVMSupportsPorts)
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudToolsCommandId,
                title: constant(String(localized: "command.cloudVM.tools.title", defaultValue: "Inspect Cloud VM Tools")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "tools", "bootstrap", "zsh", "gh", "htop", "btop"],
                when: capabilityGate(.cloudVMSupportsExec)
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudHandoffCommandId,
                title: constant(String(localized: "command.cloudVM.handoff.title", defaultValue: "Show Agent Handoff")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "agent", "handoff", "copy"]
            ),
        ]
    }

    /// Builds the Cloud-context explanation for local-only palette actions.
    /// Keeping this as a normal command makes the availability explanation
    /// searchable and gives Cloud users a localized reason for omitted rows.
    static func commandPaletteCloudAvailabilityInfoContribution(
        locale: Locale = .current
    ) -> CommandPaletteCommandContribution {
        CommandPaletteCommandContribution(
            commandId: commandPaletteCloudAvailabilityInfoCommandId,
            title: { _ in
                String(
                    localized: "command.cloudVM.availabilityInfo.title",
                    defaultValue: "Show Cloud command availability",
                    locale: locale
                )
            },
            subtitle: { _ in
                String(
                    localized: "command.cloudVM.availabilityInfo.subtitle",
                    defaultValue: "Cloud workspace",
                    locale: locale
                )
            },
            keywords: String(
                localized: "command.cloudVM.availabilityInfo.keywords",
                defaultValue: "cloud, workspace, availability, local, unavailable, actions",
                locale: locale
            )
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            when: { $0.bool(CommandPaletteContextKeys.workspaceIsCloud) }
        )
    }

    /// Registers Cloud palette handlers with the shared command dispatcher.
    func registerCloudCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        let commandWindow = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        registry.register(commandId: Self.commandPaletteCloudAvailabilityInfoCommandId) {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "command.cloudVM.availabilityInfo.alertTitle",
                defaultValue: "Some commands are local-only"
            )
            alert.informativeText = String(
                localized: "command.cloudVM.availabilityInfo.alertMessage",
                defaultValue: "Folder, simulator, local browser creation, directory search, and diff commands are available after selecting a local workspace. Cloud VM commands may be unavailable here."
            )
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            if let commandWindow {
                alert.beginSheetModal(for: commandWindow, completionHandler: nil)
            } else {
                NSSound.beep()
            }
        }
        registry.register(commandId: Self.commandPaletteCloudNewMachineCommandId) {
            _ = AppDelegate.shared?.performNewCloudMachineAction(
                tabManager: tabManager,
                preferredWindow: commandWindow,
                debugSource: "palette.cloud.newMachine"
            )
        }
        registry.register(commandId: Self.commandPaletteCloudForkCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(
                .fork,
                tabManager: tabManager,
                preferredWindow: commandWindow,
                debugSource: "palette.cloud.fork"
            )
        }
        registry.register(commandId: Self.commandPaletteCloudSnapshotCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(
                .snapshot,
                tabManager: tabManager,
                preferredWindow: commandWindow,
                debugSource: "palette.cloud.snapshot"
            )
        }
        registry.register(commandId: Self.commandPaletteCloudRestoreCommandId) {
            _ = AppDelegate.shared?.performCloudVMRestoreCommand(
                tabManager: tabManager,
                preferredWindow: commandWindow,
                debugSource: "palette.cloud.restore"
            )
        }
        registry.register(commandId: Self.commandPaletteCloudPromoteTemplateCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(
                .promoteTemplate,
                tabManager: tabManager,
                preferredWindow: commandWindow,
                debugSource: "palette.cloud.promoteTemplate"
            )
        }
        registry.register(commandId: Self.commandPaletteCloudStatusCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(
                .status,
                tabManager: tabManager,
                preferredWindow: commandWindow,
                debugSource: "palette.cloud.status"
            )
        }
        registry.register(commandId: Self.commandPaletteCloudPortsCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(
                .ports,
                tabManager: tabManager,
                preferredWindow: commandWindow,
                debugSource: "palette.cloud.ports"
            )
        }
        registry.register(commandId: Self.commandPaletteCloudToolsCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(
                .tools,
                tabManager: tabManager,
                preferredWindow: commandWindow,
                debugSource: "palette.cloud.tools"
            )
        }
        registry.register(commandId: Self.commandPaletteCloudHandoffCommandId) {
            _ = AppDelegate.shared?.performCurrentCloudVMCommand(
                .handoff,
                tabManager: tabManager,
                preferredWindow: commandWindow,
                debugSource: "palette.cloud.handoff"
            )
        }
    }
}
