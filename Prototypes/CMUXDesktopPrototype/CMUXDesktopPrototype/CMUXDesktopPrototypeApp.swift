import AppKit
import SwiftUI
import CMUXDesktopPrototypeFeature

@main
struct CMUXDesktopPrototypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1480, height: 1000)
        .commands {
            SidebarCommands()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installWindowObservers()
        configureExistingWindows()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = NotificationCenter.default
        for observer in windowObservers {
            center.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    private func installWindowObservers() {
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(
                forName: NSWindow.didBecomeMainNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else {
                    return
                }
                self?.configure(window)
            },
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else {
                    return
                }
                self?.configure(window)
            },
        ]
    }

    private func configureExistingWindows() {
        for window in NSApp.windows {
            configure(window)
        }
    }

    private func configure(_ window: NSWindow) {
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
    }
}
