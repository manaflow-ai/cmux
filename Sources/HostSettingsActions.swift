import AppKit
import CmuxSettingsUI
import Foundation
import SwiftUI

/// App-side implementation of the package's `SettingsHostActions`
/// protocol. Routes UI-triggered actions to the existing host
/// services (`BrowserHistoryStore`, `BrowserDataImportCoordinator`,
/// `TerminalNotificationStore`, etc.) so the package doesn't need to
/// depend on them directly.
@MainActor
final class HostSettingsActions: SettingsHostActions {
    private let configFileURL: URL

    /// AppKit window identifier the dedicated terminal-config window carries.
    /// Matches the value `ConfigSettingsView.configureWindow` assigns so the
    /// host reuses a config window opened from any entrypoint (the legacy
    /// in-app button's SwiftUI scene or this host-presented window).
    private let configWindowIdentifier = "cmux.configEditor"

    /// Observes the `appIconMode` defaults key the settings package writes
    /// so the host can re-apply the dock/app-switcher icon when the user
    /// changes the App Icon picker. The package only persists the value;
    /// applying `NSApplication.shared.applicationIconImage` is host work.
    ///
    /// Uses the closure-based `NSKeyValueObservation` token API, the
    /// sanctioned seam for bridging a Foundation type that exposes change
    /// only via KVO (`UserDefaults`). The token is invalidated in `deinit`.
    private var appIconModeObservation: NSKeyValueObservation?

    /// Retains the AppKit window hosting ``ConfigSettingsView`` so repeated
    /// "Open Config" presses reuse the same dedicated terminal-config
    /// window instead of stacking duplicates.
    private weak var configWindow: NSWindow?

    init(configFileURL: URL) {
        self.configFileURL = configFileURL
        startObservingAppIconMode()
    }

    deinit {
        appIconModeObservation?.invalidate()
    }

    private func startObservingAppIconMode() {
        // Apply once on construction so a value persisted before this
        // instance existed (e.g. from the config file) is reflected.
        AppIconSettings.applyIcon(AppIconSettings.resolvedMode())

        appIconModeObservation = UserDefaults.standard.observe(
            \.appIconMode,
            options: [.new]
        ) { _, _ in
            // KVO delivers on the thread that mutated the key; @AppStorage
            // writes happen on the main actor, so hop to it to apply.
            Task { @MainActor in
                AppIconSettings.applyIcon(AppIconSettings.resolvedMode())
            }
        }
    }

    func clearBrowserHistory() {
        BrowserHistoryStore.shared.clearHistory()
    }

    func openConfigInExternalEditor() {
        NSWorkspace.shared.open(configFileURL)
    }

    func sendFeedback() {
        guard let url = URL(string: "https://github.com/manaflow-ai/cmux/issues/new") else { return }
        NSWorkspace.shared.open(url)
    }

    func sendTestNotification() {
        TerminalNotificationStore.shared.sendSettingsTestNotification()
    }

    func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    func openBrowserImportFlow() {
        BrowserDataImportCoordinator.shared.presentImportDialog()
    }

    func requestNotificationAuthorization() {
        TerminalNotificationStore.shared.requestAuthorizationFromSettings()
    }

    func openTerminalConfigWindow() {
        NSApp.activate(ignoringOtherApps: true)

        // Legacy opened the dedicated config window via the SwiftUI
        // `openWindow(id: ConfigSettingsView.windowID)` environment. The
        // settings package can't reach that environment, so the host opens
        // the same `ConfigSettingsView` directly. Reuse the existing window
        // (identifier set by `ConfigSettingsView.configureWindow`) when one
        // is already open so repeated presses focus instead of duplicate.
        if let existing = existingConfigWindow() {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        let appearanceMode = UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
        let root = ConfigSettingsView()
            .cmuxAppearanceColorScheme(appearanceMode)
        let hostingController = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "settings.config.windowTitle", defaultValue: "Config")
        window.identifier = NSUserInterfaceItemIdentifier(configWindowIdentifier)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 980, height: 680))
        window.center()
        configWindow = window
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func existingConfigWindow() -> NSWindow? {
        if let configWindow, configWindow.isVisible || configWindow.isMiniaturized {
            return configWindow
        }
        return NSApp.windows.first {
            $0.identifier?.rawValue == configWindowIdentifier && ($0.isVisible || $0.isMiniaturized)
        }
    }

    func previewNotificationSound() {
        NSSound(named: NSSound.Name("Glass"))?.play()
    }

    func browserHistoryEntryCount() -> Int? {
        guard BrowserHistoryStore.shared.isLoaded else { return nil }
        return BrowserHistoryStore.shared.entries.count
    }
}

private extension UserDefaults {
    /// KVO-observable accessor for the `appIconMode` defaults key.
    ///
    /// `UserDefaults` is KVO-compliant for any key accessed through a
    /// matching `@objc dynamic` property whose name equals the key, which
    /// lets ``HostSettingsActions`` observe App Icon changes the settings
    /// package writes via `@AppStorage`. The property name must stay equal
    /// to ``AppIconSettings/modeKey`` (`"appIconMode"`).
    @objc dynamic var appIconMode: String? {
        string(forKey: "appIconMode")
    }
}
