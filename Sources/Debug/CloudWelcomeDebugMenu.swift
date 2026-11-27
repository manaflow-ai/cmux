#if DEBUG
import AppKit
import SwiftUI

extension cmuxApp {
    /// Deliberately reopen the shipped welcome for inspection in a debug build.
    @ViewBuilder
    var cloudWelcomeDebugMenuItems: some View {
        Button(String(localized: "debug.menu.showCloudWelcome", defaultValue: "Show Cloud Welcome…")) {
            AppDelegate.shared?.cloudWelcomeWindowController.presentForDebug(over: NSApp.mainWindow)
        }
        Button(String(localized: "debug.menu.showCloudWelcomeFBadge", defaultValue: "Show Cloud Welcome (F, New Badge)…")) {
            AppDelegate.shared?.cloudWelcomeWindowController.presentForDebug(
                over: NSApp.mainWindow,
                posterShowsTitle: false,
                showsNewBadge: true,
                footerHasNotNow: true
            )
        }
        Button(String(localized: "debug.menu.showCloudWelcomeFOnClip", defaultValue: "Show Cloud Welcome (F, On Clip)…")) {
            AppDelegate.shared?.cloudWelcomeWindowController.presentForDebug(
                over: NSApp.mainWindow,
                posterShowsIcon: false,
                footerHasNotNow: true
            )
        }
    }
}
#endif
