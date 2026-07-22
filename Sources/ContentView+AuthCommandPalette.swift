import CmuxCommandPalette
import AppKit
import Foundation

@MainActor
struct CommandPaletteAuthActions {
    let isAuthenticated: Bool
    let isWorking: Bool
    let beginSignIn: @MainActor (NSWindow) -> Bool
    let signOut: @MainActor () async -> Void
}

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

    static func commandPaletteAuthFailureResult(code: String) -> CmuxActionExecutionResult {
        .failed(
            code: code,
            message: String(
                localized: "action.error.configuredActionFailed",
                defaultValue: "The configured action could not be started."
            )
        )
    }

    private static func liveCommandPaletteAuthActions() -> CommandPaletteAuthActions? {
        guard let auth = AppDelegate.shared?.auth else { return nil }
        return CommandPaletteAuthActions(
            isAuthenticated: auth.coordinator.isAuthenticated,
            isWorking: auth.coordinator.isLoading
                || auth.coordinator.isRestoringSession
                || auth.browserSignIn.isSigningIn,
            beginSignIn: { window in
                auth.browserSignIn.beginSignIn(presentationAnchor: window)
                return auth.browserSignIn.isPresentingSignIn
            },
            signOut: {
                await auth.browserSignIn.signOut()
            }
        )
    }

    private func commandPaletteAuthTargetWindow(
        _ context: CommandPaletteActionContext
    ) -> NSWindow? {
        guard context.target.windowID == windowId,
              context.owningWindowID == windowId,
              let appDelegate = AppDelegate.shared,
              let liveContext = appDelegate.liveMainWindowContextForAction(
                tabManager: context.tabManager
              ),
              liveContext.windowId == context.target.windowID,
              let window = appDelegate.mainWindow(for: context.target.windowID) else {
            return nil
        }
        if context.target.panelID != nil, context.panel() == nil {
            return nil
        }
        if context.target.workspaceID != nil, context.workspace() == nil {
            return nil
        }
        return window
    }

    private static func commandPaletteAuthRejected(
        _ result: CmuxActionExecutionResult,
        invocation: CmuxActionInvocation,
        beep: @MainActor () -> Void
    ) -> CmuxActionExecutionResult {
        if invocation.source == .commandPalette {
            beep()
        }
        return result
    }

    func registerAuthCommandHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        context: CommandPaletteActionContext,
        authActions providedAuthActions: (@MainActor () -> CommandPaletteAuthActions?)? = nil,
        beep: @escaping @MainActor () -> Void = { NSSound.beep() }
    ) {
        let authActions = providedAuthActions ?? { Self.liveCommandPaletteAuthActions() }
        registry.register(commandId: Self.commandPaletteAuthSignInCommandId) { invocation in
#if DEBUG
            cmuxDebugLog("palette.auth.signIn.invoke")
#endif
            guard let targetWindow = commandPaletteAuthTargetWindow(context) else {
                return Self.commandPaletteAuthRejected(
                    .targetUnavailable,
                    invocation: invocation,
                    beep: beep
                )
            }
            guard let actions = authActions() else {
                return Self.commandPaletteAuthRejected(
                    Self.commandPaletteAuthFailureResult(code: "auth_unavailable"),
                    invocation: invocation,
                    beep: beep
                )
            }
            if actions.isAuthenticated {
                return .completed
            }
            guard !actions.isWorking else {
                return Self.commandPaletteAuthRejected(
                    Self.commandPaletteAuthFailureResult(code: "action_in_progress"),
                    invocation: invocation,
                    beep: beep
                )
            }
            guard actions.beginSignIn(targetWindow) else {
                return Self.commandPaletteAuthRejected(
                    Self.commandPaletteAuthFailureResult(code: "auth_sign_in_failed"),
                    invocation: invocation,
                    beep: beep
                )
            }
            return .presented
        }
        registry.register(commandId: Self.commandPaletteAuthSignOutCommandId) { invocation in
#if DEBUG
            cmuxDebugLog("palette.auth.signOut.invoke")
#endif
            guard commandPaletteAuthTargetWindow(context) != nil else {
                return Self.commandPaletteAuthRejected(
                    .targetUnavailable,
                    invocation: invocation,
                    beep: beep
                )
            }
            guard let actions = authActions() else {
                return Self.commandPaletteAuthRejected(
                    Self.commandPaletteAuthFailureResult(code: "auth_unavailable"),
                    invocation: invocation,
                    beep: beep
                )
            }
            guard actions.isAuthenticated || actions.isWorking else {
                return .completed
            }
            Task { @MainActor in
                await actions.signOut()
            }
            return .queued
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

    static func commandPaletteCloudRestoreResult(
        hasSnapshotID: Bool,
        didStart: Bool,
        source: CmuxActionInvocationSource = .commandPalette
    ) -> CmuxActionExecutionResult {
        guard hasSnapshotID else {
            if source == .commandPalette { return .presented }
            return .failed(
                code: "action_failed",
                message: String(
                    localized: "action.error.cloudVMRestoreFailed",
                    defaultValue: "Cloud VM restore could not be started."
                )
            )
        }
        guard didStart else {
            return .failed(
                code: "action_failed",
                message: String(
                    localized: "action.error.cloudVMRestoreFailed",
                    defaultValue: "Cloud VM restore could not be started."
                )
            )
        }
        return .queued
    }

    static func commandPaletteCloudStartResult(
        didStart: Bool
    ) -> CmuxActionExecutionResult {
        guard didStart else {
            return .failed(
                code: "action_failed",
                message: String(
                    localized: "action.error.configuredActionFailed",
                    defaultValue: "The configured action could not be started."
                )
            )
        }
        return .queued
    }

    static func commandPaletteCloudPresentationPolicy(
        for source: CmuxActionInvocationSource
    ) -> CloudVMActionPresentationPolicy {
        source == .automation ? .automation : .interactive
    }

    static func commandPaletteCloudCommandContributions() -> [CommandPaletteCommandContribution] {
        // Feature-gated: hide every Cloud VM command from the palette when the
        // Cloud VM UI flag is off, matching the dropdown and shortcut gates.
        guard CmuxFeatureFlags.shared.isCloudVMUIEnabled else { return [] }
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }
        func requiresCurrentCloudVM(_ context: CommandPaletteContextSnapshot) -> Bool {
            context.bool(CommandPaletteContextKeys.hasWorkspace)
                && context.bool(CommandPaletteContextKeys.workspaceHasCloudVM)
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
                keywords: ["cloud", "vm", "fork", "clone", "branch"],
                when: requiresCurrentCloudVM
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudSnapshotCommandId,
                title: constant(String(localized: "command.cloudVM.snapshot.title", defaultValue: "Checkpoint Current Cloud VM")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "snapshot", "checkpoint", "save"],
                when: requiresCurrentCloudVM
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudRestoreCommandId,
                title: constant(String(localized: "command.cloudVM.restore.title", defaultValue: "Restore Cloud VM From Checkpoint")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "restore", "snapshot", "checkpoint"],
                arguments: [CmuxActionArgumentDefinition(name: "snapshot_id")]
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudPromoteTemplateCommandId,
                title: constant(String(localized: "command.cloudVM.promoteTemplate.title", defaultValue: "Promote Current VM to Template")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "template", "promote", "snapshot"],
                when: requiresCurrentCloudVM
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudStatusCommandId,
                title: constant(String(localized: "command.cloudVM.status.title", defaultValue: "Show Cloud VM Status")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "status", "running", "paused"],
                when: requiresCurrentCloudVM
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudPortsCommandId,
                title: constant(String(localized: "command.cloudVM.ports.title", defaultValue: "Show Cloud VM Ports")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "ports", "preview", "localhost"],
                when: requiresCurrentCloudVM
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudToolsCommandId,
                title: constant(String(localized: "command.cloudVM.tools.title", defaultValue: "Inspect Cloud VM Tools")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "tools", "bootstrap", "zsh", "gh", "htop", "btop"],
                when: requiresCurrentCloudVM
            ),
            CommandPaletteCommandContribution(
                commandId: commandPaletteCloudHandoffCommandId,
                title: constant(String(localized: "command.cloudVM.handoff.title", defaultValue: "Show Agent Handoff")),
                subtitle: subtitle,
                keywords: ["cloud", "vm", "agent", "handoff", "copy"],
                when: requiresCurrentCloudVM
            ),
        ]
    }

    func registerCloudCommandHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        context: CommandPaletteActionContext,
        configCatalog: CmuxConfigActionCatalog
    ) {
        func targetWindow(_ appDelegate: AppDelegate) -> NSWindow? {
            guard context.target.windowID == windowId,
                  context.owningWindowID == windowId,
                  let liveContext = appDelegate.liveMainWindowContextForAction(
                    tabManager: context.tabManager
                  ),
                  liveContext.windowId == context.target.windowID else {
                return nil
            }
            return appDelegate.mainWindow(for: context.target.windowID)
        }

        func targetWorkspaceID() -> UUID? {
            context.workspace()?.id
        }

        registry.register(commandId: Self.commandPaletteCloudOpenCommandId) { _ in
            guard let appDelegate = AppDelegate.shared,
                  targetWindow(appDelegate) != nil else {
                return .targetUnavailable
            }
            return executeConfiguredPaletteAction(
                id: CmuxSurfaceTabBarBuiltInAction.cloudVM.configID,
                context: context,
                configCatalog: configCatalog
            )
        }
        registry.register(commandId: Self.commandPaletteCloudForkCommandId) { invocation in
            guard let workspaceID = targetWorkspaceID() else { return .targetUnavailable }
            guard let appDelegate = AppDelegate.shared else {
                return Self.commandPaletteCloudStartResult(didStart: false)
            }
            let didStart = appDelegate.performCurrentCloudVMCommand(
                .fork,
                workspaceID: workspaceID,
                tabManager: context.tabManager,
                preferredWindow: targetWindow(appDelegate),
                presentationPolicy: Self.commandPaletteCloudPresentationPolicy(for: invocation.source),
                debugSource: "palette.cloud.fork"
            )
            return Self.commandPaletteCloudStartResult(didStart: didStart)
        }
        registry.register(commandId: Self.commandPaletteCloudSnapshotCommandId) { invocation in
            guard let workspaceID = targetWorkspaceID() else { return .targetUnavailable }
            guard let appDelegate = AppDelegate.shared else {
                return Self.commandPaletteCloudStartResult(didStart: false)
            }
            let didStart = appDelegate.performCurrentCloudVMCommand(
                .snapshot,
                workspaceID: workspaceID,
                tabManager: context.tabManager,
                preferredWindow: targetWindow(appDelegate),
                presentationPolicy: Self.commandPaletteCloudPresentationPolicy(for: invocation.source),
                debugSource: "palette.cloud.snapshot"
            )
            return Self.commandPaletteCloudStartResult(didStart: didStart)
        }
        registry.register(commandId: Self.commandPaletteCloudRestoreCommandId) { invocation in
            guard let appDelegate = AppDelegate.shared,
                  let targetWindow = targetWindow(appDelegate) else {
                return .targetUnavailable
            }
            let snapshotId = invocation.string("snapshot_id")
            let didStart = appDelegate.performCloudVMRestoreCommand(
                snapshotId: snapshotId,
                tabManager: context.tabManager,
                preferredWindow: targetWindow,
                presentationPolicy: Self.commandPaletteCloudPresentationPolicy(for: invocation.source),
                debugSource: "palette.cloud.restore"
            )
            return Self.commandPaletteCloudRestoreResult(
                hasSnapshotID: snapshotId != nil,
                didStart: didStart,
                source: invocation.source
            )
        }
        registry.register(commandId: Self.commandPaletteCloudPromoteTemplateCommandId) { invocation in
            guard let workspaceID = targetWorkspaceID() else { return .targetUnavailable }
            guard let appDelegate = AppDelegate.shared else {
                return Self.commandPaletteCloudStartResult(didStart: false)
            }
            let didStart = appDelegate.performCurrentCloudVMCommand(
                .promoteTemplate,
                workspaceID: workspaceID,
                tabManager: context.tabManager,
                preferredWindow: targetWindow(appDelegate),
                presentationPolicy: Self.commandPaletteCloudPresentationPolicy(for: invocation.source),
                debugSource: "palette.cloud.promoteTemplate"
            )
            return Self.commandPaletteCloudStartResult(didStart: didStart)
        }
        registry.register(commandId: Self.commandPaletteCloudStatusCommandId) { invocation in
            guard let workspaceID = targetWorkspaceID() else { return .targetUnavailable }
            guard let appDelegate = AppDelegate.shared else {
                return Self.commandPaletteCloudStartResult(didStart: false)
            }
            let didStart = appDelegate.performCurrentCloudVMCommand(
                .status,
                workspaceID: workspaceID,
                tabManager: context.tabManager,
                preferredWindow: targetWindow(appDelegate),
                presentationPolicy: Self.commandPaletteCloudPresentationPolicy(for: invocation.source),
                debugSource: "palette.cloud.status"
            )
            return Self.commandPaletteCloudStartResult(didStart: didStart)
        }
        registry.register(commandId: Self.commandPaletteCloudPortsCommandId) { invocation in
            guard let workspaceID = targetWorkspaceID() else { return .targetUnavailable }
            guard let appDelegate = AppDelegate.shared else {
                return Self.commandPaletteCloudStartResult(didStart: false)
            }
            let didStart = appDelegate.performCurrentCloudVMCommand(
                .ports,
                workspaceID: workspaceID,
                tabManager: context.tabManager,
                preferredWindow: targetWindow(appDelegate),
                presentationPolicy: Self.commandPaletteCloudPresentationPolicy(for: invocation.source),
                debugSource: "palette.cloud.ports"
            )
            return Self.commandPaletteCloudStartResult(didStart: didStart)
        }
        registry.register(commandId: Self.commandPaletteCloudToolsCommandId) { invocation in
            guard let workspaceID = targetWorkspaceID() else { return .targetUnavailable }
            guard let appDelegate = AppDelegate.shared else {
                return Self.commandPaletteCloudStartResult(didStart: false)
            }
            let didStart = appDelegate.performCurrentCloudVMCommand(
                .tools,
                workspaceID: workspaceID,
                tabManager: context.tabManager,
                preferredWindow: targetWindow(appDelegate),
                presentationPolicy: Self.commandPaletteCloudPresentationPolicy(for: invocation.source),
                debugSource: "palette.cloud.tools"
            )
            return Self.commandPaletteCloudStartResult(didStart: didStart)
        }
        registry.register(commandId: Self.commandPaletteCloudHandoffCommandId) { invocation in
            guard let workspaceID = targetWorkspaceID() else { return .targetUnavailable }
            guard let appDelegate = AppDelegate.shared else {
                return Self.commandPaletteCloudStartResult(didStart: false)
            }
            let didStart = appDelegate.performCurrentCloudVMCommand(
                .handoff,
                workspaceID: workspaceID,
                tabManager: context.tabManager,
                preferredWindow: targetWindow(appDelegate),
                presentationPolicy: Self.commandPaletteCloudPresentationPolicy(for: invocation.source),
                debugSource: "palette.cloud.handoff"
            )
            return Self.commandPaletteCloudStartResult(didStart: didStart)
        }
    }
}
