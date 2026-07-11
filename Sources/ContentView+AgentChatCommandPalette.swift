import AppKit
import CmuxCommandPalette

extension ContentView {
    func commandPaletteConfigActionID(for commandId: String) -> String? {
        switch commandId {
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

    func registerAgentChatCommandPaletteHandler(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.newAgentChat") {
            guard CmuxFeatureFlags.shared.isAgentChatUIEnabled else {
                NSSound.beep()
                return
            }
            guard let appDelegate = AppDelegate.shared else {
                NSSound.beep()
                return
            }
            if !appDelegate.executeConfiguredCmuxAction(
                id: CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID,
                tabManager: tabManager,
                preferredWindow: appDelegate.mainWindow(for: windowId)
            ) {
                NSSound.beep()
            }
        }
    }
}
