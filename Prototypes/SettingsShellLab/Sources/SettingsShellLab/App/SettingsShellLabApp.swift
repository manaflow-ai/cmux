import AppKit
import SwiftUI

@main
struct SettingsShellLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(String(localized: "app.window.title", defaultValue: "Settings Shell Lab")) {
            SettingsShellView()
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            SidebarCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
