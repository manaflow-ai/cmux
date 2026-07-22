import AppKit
import CmuxCommandPalette

extension ContentView {
    func commandPaletteConfigActionID(for commandId: String) -> String? {
        Self.commandPaletteBuiltInConfigActionID(for: commandId)
    }

    static func commandPaletteBuiltInConfigActionID(for commandId: String) -> String? {
        switch commandId {
        case "palette.newWorkspace":
            return CmuxSurfaceTabBarBuiltInAction.newWorkspace.configID
        case commandPaletteCloudOpenCommandId:
            return CmuxSurfaceTabBarBuiltInAction.cloudVM.configID
        case "palette.mobileConnect":
            return CmuxSurfaceTabBarBuiltInAction.mobileConnect.configID
        case "palette.newTerminalTab":
            return CmuxSurfaceTabBarBuiltInAction.newTerminal.configID
        case "palette.newBrowserTab":
            return CmuxSurfaceTabBarBuiltInAction.newBrowser.configID
        case "palette.newAgentChat":
            return CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID
        case "palette.terminalSplitRight":
            return CmuxSurfaceTabBarBuiltInAction.splitRight.configID
        case "palette.terminalSplitDown":
            return CmuxSurfaceTabBarBuiltInAction.splitDown.configID
        default:
            return nil
        }
    }

    static func commandPaletteNewAgentChatContributions() -> [CommandPaletteCommandContribution] {
        guard CmuxFeatureFlags.shared.isAgentChatUIEnabled else { return [] }
        return [CommandPaletteCommandContribution(
            commandId: "palette.newAgentChat",
            title: { _ in String(localized: "command.newAgentChat.title", defaultValue: "New agent chat") },
            subtitle: { _ in String(localized: "command.newAgentChat.subtitle", defaultValue: "Agent Chat") },
            keywords: ["create", "new", "agent", "chat", "browser", "codex", "claude"],
            when: { !$0.bool(CommandPaletteContextKeys.browserDisabled) }
        )]
    }

    func registerAgentChatCommandPaletteHandler(
        _ registry: inout CommandPaletteHandlerRegistry,
        context: CommandPaletteActionContext,
        configCatalog: CmuxConfigActionCatalog,
        beep: @escaping @MainActor () -> Void = { NSSound.beep() }
    ) {
        registry.register(commandId: "palette.newAgentChat") { invocation in
            guard CmuxFeatureFlags.shared.isAgentChatUIEnabled else {
                if invocation.source == .commandPalette { beep() }
                return .failed(
                    code: "action_unavailable",
                    message: String(
                        localized: "action.error.configuredActionFailed",
                        defaultValue: "The configured action could not be started."
                    )
                )
            }
            guard context.target.windowID == windowId else {
                if invocation.source == .commandPalette { beep() }
                return .targetUnavailable
            }
            return executeConfiguredPaletteAction(
                id: CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID,
                context: context,
                configCatalog: configCatalog,
                invocationSource: invocation.source
            )
        }
    }
}
