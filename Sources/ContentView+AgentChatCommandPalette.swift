import AppKit
import CmuxCommandPalette
import CmuxWorkspaces

extension ContentView {
    func registerAgentChatCommandPaletteHandler(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.newAgentChat") {
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
