import AppKit
import SwiftUI

@main
struct cmuxApp: App {
    @StateObject private var tabManager = TabManager()
    @StateObject private var notificationStore = TerminalNotificationStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Start the terminal controller for programmatic control
        // This runs after TabManager is created via @StateObject
    }

    var body: some Scene {
        WindowGroup {
            ContentView(updateViewModel: appDelegate.updateViewModel)
                .environmentObject(tabManager)
                .environmentObject(notificationStore)
                .onAppear {
                    // Start the Unix socket controller for programmatic access
                    TerminalController.shared.start(tabManager: tabManager)
                    appDelegate.configure(tabManager: tabManager, notificationStore: notificationStore)
                }
        }
        .windowToolbarStyle(.automatic)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About cmuxterm") {
                    showAboutPanel()
                }
                Divider()
                Button("Check for Updates…") {
                    appDelegate.checkForUpdates(nil)
                }
            }

            CommandMenu("Update Pill") {
                Button("Show Update Pill") {
                    appDelegate.showUpdatePill(nil)
                }
                Button("Show Loading State") {
                    appDelegate.showUpdatePillLoading(nil)
                }
                Button("Hide Update Pill") {
                    appDelegate.hideUpdatePill(nil)
                }
                Button("Automatic Update Pill") {
                    appDelegate.clearUpdatePillOverride(nil)
                }
            }

            CommandMenu("Update Logs") {
                Button("Copy Update Logs") {
                    appDelegate.copyUpdateLogs(nil)
                }
            }

            // New tab commands
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    tabManager.addTab()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("New Tab") {
                    tabManager.addTab()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Tab") {
                    tabManager.addTab()
                }
                .keyboardShortcut("`", modifiers: [.control, .shift])
            }

            // Close tab
            CommandGroup(after: .newItem) {
                Button("Close Panel") {
                    tabManager.closeCurrentPanelWithConfirmation()
                }
                .keyboardShortcut("w", modifiers: .command)

                Button("Close Tab") {
                    tabManager.closeCurrentTabWithConfirmation()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            // Tab navigation
            CommandGroup(after: .toolbar) {
                Button("Next Tab") {
                    tabManager.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Tab") {
                    tabManager.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Next Tab") {
                    tabManager.selectNextTab()
                }
                .keyboardShortcut(.tab, modifiers: .control)

                Button("Previous Tab") {
                    tabManager.selectPreviousTab()
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

                Divider()

                // Cmd+1 through Cmd+9 for tab selection
                ForEach(1...9, id: \.self) { number in
                    Button("Tab \(number)") {
                        if number == 9 {
                            tabManager.selectLastTab()
                        } else {
                            tabManager.selectTab(at: number - 1)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
            }
        }
    }

    private func showAboutPanel() {
        let bundle = Bundle.main
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "cmuxterm"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appName,
            .version: version,
            .applicationVersion: build
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
