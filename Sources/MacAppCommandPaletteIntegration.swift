import AppKit
import CmuxCommandPalette
import Foundation

extension CommandPaletteCommandContribution {
    static var newMacAppPane: Self {
        Self(
            commandId: "palette.newMacAppPane",
            title: { _ in
                String(localized: "command.newMacAppPane.title", defaultValue: "New Mac App Pane")
            },
            subtitle: { _ in
                String(localized: "command.newMacAppPane.subtitle", defaultValue: "Mirror and interact with an open app")
            },
            keywords: ["new", "mac", "app", "window", "mirror", "capture", "pane"]
        )
    }
}

extension CommandPaletteHandlerRegistry {
    @MainActor
    mutating func registerNewMacAppPane(tabManager: TabManager, windowId: UUID) {
        register(commandId: "palette.newMacAppPane") {
            guard let appDelegate = AppDelegate.shared,
                  appDelegate.executeConfiguredCmuxAction(
                      id: CmuxSurfaceTabBarBuiltInAction.newMacApp.configID,
                      tabManager: tabManager,
                      preferredWindow: appDelegate.mainWindow(for: windowId)
                  ) else {
                NSSound.beep()
                return
            }
        }
    }
}
