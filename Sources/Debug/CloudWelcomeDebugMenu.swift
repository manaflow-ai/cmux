#if DEBUG
import AppKit
import SwiftUI

extension cmuxApp {
    /// Debug-only Help menu entries for comparing the Cloud welcome layouts.
    @ViewBuilder
    var cloudWelcomeDebugMenuItems: some View {
        Button(String(localized: "debug.menu.showCloudWelcome", defaultValue: "Show Cloud Welcome…")) {
            AppDelegate.shared?.cloudWelcomeWindowController.present(
                over: NSApp.mainWindow,
                sliderShowsFeatureList: false
            )
        }
        Button(String(localized: "debug.menu.showCloudWelcomeList", defaultValue: "Show Cloud Welcome (List)…")) {
            AppDelegate.shared?.cloudWelcomeWindowController.present(over: NSApp.mainWindow, sliderShowsFeatureList: true)
        }
        Button(String(localized: "debug.menu.showCloudWelcomeListDots", defaultValue: "Show Cloud Welcome (List + Dots)…")) {
            AppDelegate.shared?.cloudWelcomeWindowController.present(
                over: NSApp.mainWindow,
                sliderShowsFeatureList: true,
                sliderListUsesDots: true
            )
        }
    }
}
#endif
