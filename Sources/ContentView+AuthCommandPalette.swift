import CmuxCommandPalette
import AppKit
import Foundation

extension ContentView {
    static let commandPaletteAuthSignInCommandId = "palette.auth.signIn"
    static let commandPaletteAuthSignOutCommandId = "palette.auth.signOut"

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
            auth.browserSignIn.beginSignIn()
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
                await auth.browserSignIn.signOut()
            }
        }
    }
}

extension ContentView {
    static let commandPaletteCloudOpenCommandId = "palette.cloud.open"
    static let commandPaletteCloudForkCommandId = "palette.cloud.fork"
    static let commandPaletteCloudSnapshotCommandId = "palette.cloud.snapshot"
    static let commandPaletteCloudRestoreCommandId = "palette.cloud.restore"
    static let commandPaletteCloudPromoteTemplateCommandId = "palette.cloud.promoteTemplate"
    static let commandPaletteCloudStatusCommandId = "palette.cloud.status"
    static let commandPaletteCloudPortsCommandId = "palette.cloud.ports"
    static let commandPaletteCloudToolsCommandId = "palette.cloud.tools"
    static let commandPaletteCloudHandoffCommandId = "palette.cloud.handoff"

    static func commandPaletteCloudCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }
        let subtitle = constant(String(localized: "command.cloudVM.subtitle", defaultValue: "Cloud"))
        return [
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudOpenCommandId,
                title: constant(String(localized: "command.cloudVM.open.title", defaultValue: "Open Base")),
                subtitle: subtitle,
                keywords: ["base", "cloud", "vm", "ssh", "sshd", "open", "reconnect"]
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
        registry.register(commandId: Self.commandPaletteCloudOpenCommandId) {
            _ = AppDelegate.shared?.performCloudVMAction(debugSource: "palette.cloud.open")
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
