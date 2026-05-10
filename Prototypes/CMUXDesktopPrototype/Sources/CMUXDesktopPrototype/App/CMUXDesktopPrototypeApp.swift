import AppKit
import SwiftUI

@main
struct CMUXDesktopPrototypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(String(localized: "app.window.title", defaultValue: "cmux Desktop Prototype", bundle: .module)) {
            DesktopPrototypeView()
        }
        .defaultSize(width: 1120, height: 760)
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
