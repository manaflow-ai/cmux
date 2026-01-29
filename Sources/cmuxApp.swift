import AppKit
import SwiftUI

@main
struct cmuxApp: App {
    @StateObject private var tabManager = TabManager()
    @StateObject private var notificationStore = TerminalNotificationStore.shared
    @StateObject private var sidebarState = SidebarState()
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.dark.rawValue
    @AppStorage("titlebarControlsStyle") private var titlebarControlsStyle = TitlebarControlsStyle.classic.rawValue
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
                .environmentObject(sidebarState)
                .onAppear {
                    // Start the Unix socket controller for programmatic access
                    TerminalController.shared.start(tabManager: tabManager)
                    appDelegate.configure(tabManager: tabManager, notificationStore: notificationStore, sidebarState: sidebarState)
                    applyAppearance()
                }
                .onChange(of: appearanceMode) { _ in
                    applyAppearance()
                }
        }
        .windowToolbarStyle(.automatic)
        Settings {
            SettingsRootView()
        }
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

#if DEBUG
            CommandMenu("Debug") {
                Button("New Tab With Large Scrollback") {
                    appDelegate.openDebugScrollbackTab(nil)
                }

                Divider()

                Picker("Titlebar Controls Style", selection: $titlebarControlsStyle) {
                    ForEach(TitlebarControlsStyle.allCases) { style in
                        Text(style.menuTitle).tag(style.rawValue)
                    }
                }
            }
#endif

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
                Button("Toggle Sidebar") {
                    sidebarState.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)

                Divider()

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

                Divider()

                Button("Jump to Latest Unread") {
                    jumpToLatestUnread()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button("Show Notifications") {
                    showNotificationsPopover()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
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

    private func applyAppearance() {
        guard let mode = AppearanceMode(rawValue: appearanceMode) else { return }
        switch mode {
        case .auto:
            NSApp.appearance = nil
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
            NSApp.appearance = NSAppearance(named: match)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func jumpToLatestUnread() {
        guard let notification = notificationStore.notifications.first(where: { !$0.isRead }) else { return }
        tabManager.focusTabFromNotification(notification.tabId, surfaceId: notification.surfaceId)
    }

    private func showNotificationsPopover() {
        AppDelegate.shared?.toggleNotificationsPopover()
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto
    case system
    case dark

    var id: String { rawValue }
}

struct SettingsView: View {
    @AppStorage("appearanceMode") private var appearanceMode = AppearanceMode.dark.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Theme")
                .font(.headline)

            Picker("Theme", selection: $appearanceMode) {
                Text("Auto").tag(AppearanceMode.auto.rawValue)
                Text("System").tag(AppearanceMode.system.rawValue)
                Text("Dark").tag(AppearanceMode.dark.rawValue)
            }
            .pickerStyle(.radioGroup)
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 180)
    }
}

private struct SettingsRootView: View {
    var body: some View {
        SettingsView()
            .background(WindowAccessor { window in
                window.identifier = NSUserInterfaceItemIdentifier("cmux.settings")
            })
    }
}
