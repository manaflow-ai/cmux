import AppKit

extension cmuxApp {
    func performNewMacAppPaneFromMenu() {
        guard let appDelegate = AppDelegate.shared,
              appDelegate.executeConfiguredCmuxAction(
                  id: CmuxSurfaceTabBarBuiltInAction.newMacApp.configID,
                  tabManager: activeTabManager,
                  preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
              ) else {
            NSSound.beep()
            return
        }
    }
}
