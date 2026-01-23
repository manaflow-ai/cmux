import SwiftUI

@main
struct GhosttyTabsApp: App {
    @StateObject private var tabManager = TabManager()
    @StateObject private var notificationStore = TerminalNotificationStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Start the terminal controller for programmatic control
        // This runs after TabManager is created via @StateObject
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tabManager)
                .environmentObject(notificationStore)
                .onAppear {
                    // Start the Unix socket controller for programmatic access
                    TerminalController.shared.start(tabManager: tabManager)
                    appDelegate.configure(tabManager: tabManager, notificationStore: notificationStore)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
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
                Button("Close Tab") {
                    tabManager.closeCurrentTab()
                }
                .keyboardShortcut("w", modifiers: .command)
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
                        tabManager.selectTab(at: number - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
            }
        }
    }
}
