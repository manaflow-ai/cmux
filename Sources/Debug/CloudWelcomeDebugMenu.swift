#if DEBUG
import AppKit
import SwiftUI

extension cmuxApp {
    /// Debug-only Help menu entries for comparing the Cloud welcome headlines.
    @ViewBuilder
    var cloudWelcomeDebugMenuItems: some View {
        Button(String(localized: "debug.menu.showCloudWelcome", defaultValue: "Show Cloud Welcome…")) {
            AppDelegate.shared?.cloudWelcomeWindowController.present(over: NSApp.mainWindow)
        }
        Button(String(localized: "debug.menu.showCloudWelcomeHeadline", defaultValue: "Show Cloud Welcome (Headline)…")) {
            AppDelegate.shared?.cloudWelcomeWindowController.present(
                over: NSApp.mainWindow,
                posterHeadline: String(localized: "cloud.welcome.headline", defaultValue: "Cloud machines for your agents")
            )
        }
        Button(String(localized: "debug.menu.showCloudWelcomeFBadge", defaultValue: "Show Cloud Welcome (F, New Badge)…")) {
            AppDelegate.shared?.cloudWelcomeWindowController.present(
                over: NSApp.mainWindow,
                posterHeadline: String(localized: "cloud.welcome.headline", defaultValue: "Cloud machines for your agents"),
                posterShowsTitle: false,
                showsNewBadge: true,
                footerHasNotNow: true
            )
        }
        Button(String(localized: "debug.menu.showCloudWelcomeFOnClip", defaultValue: "Show Cloud Welcome (F, On Clip)…")) {
            AppDelegate.shared?.cloudWelcomeWindowController.present(
                over: NSApp.mainWindow,
                posterHeadline: String(localized: "cloud.welcome.headline", defaultValue: "Cloud machines for your agents"),
                posterShowsIcon: false,
                footerHasNotNow: true
            )
        }
    }
}
#endif
