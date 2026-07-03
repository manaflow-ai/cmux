import AppKit
import CMUXMobileCore
import CmuxWorkspaces
import CmuxSettingsUI
import CmuxFoundation
import Foundation
import OSLog
import SwiftUI

nonisolated private let hostSettingsLogger = Logger(subsystem: "com.cmuxterm.app", category: "Settings")

/// App-side implementation of the package's `SettingsHostActions`
/// protocol. Routes UI-triggered actions to the existing host
/// services (`BrowserHistoryStore`, `BrowserDataImportCoordinator`,
/// `TerminalNotificationStore`, etc.) so the package doesn't need to
/// depend on them directly.
@MainActor
final class HostSettingsActions: SettingsHostActions {
    private let configFileURL: URL

    /// Serializes font config writes so rapid control changes persist in order.
    private let fontConfigWriter = FontConfigWriter()

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
    private var configWindow: NSWindow?
    private var configWindowCloseObserver: WindowCloseObserver?

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

    func sleepyModePreview() {
        SleepyModeController.shared.preview()
    }

    func sleepyModeStart() {
        SleepyModeController.shared.activate()
    }

    func sleepyModeStore() -> SleepyModeSettingsStore {
        SleepyModeController.shared.store
    }

    func resetAllSettingsSideEffects() {
        PaneChromeSettings.notifyDidChange()
    }

    func openConfigInExternalEditor() {
        // Honor the user's configured editor (`preferredEditorCommand`),
        // falling back to the OS default. Opening the config file directly
        // through `NSWorkspace.shared.open` would route to the default
        // `.json` handler and ignore the cmux setting.
        PreferredEditorService(defaults: .standard).open(configFileURL)
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
        configWindowCloseObserver = WindowCloseObserver(window: window) { [weak self] in
            self?.releaseConfigWindow($0)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func setMenuBarOnly(_ enabled: Bool) -> Bool {
        MenuBarOnlySettings.setEnabled(enabled)
        return true
    }

    func openMobilePairingWindow() {
        MobilePairingWindowController.shared.show()
    }

    private func existingConfigWindow() -> NSWindow? {
        if let configWindow, configWindow.isVisible || configWindow.isMiniaturized {
            return configWindow
        }
        return NSApp.windows.first {
            $0.identifier?.rawValue == configWindowIdentifier && ($0.isVisible || $0.isMiniaturized)
        }
    }

    private func releaseConfigWindow(_ window: NSWindow) {
        guard configWindow === window else { return }
        configWindowCloseObserver = nil
        window.contentView = nil
        window.contentViewController = nil
        configWindow = nil
    }

    func previewNotificationSound(value: String, customFilePath: String) {
        NotificationSoundSettings.previewSound(value: value, customFilePath: customFilePath)
    }

    func browserHistoryEntryCount() -> Int? {
        guard BrowserHistoryStore.shared.isLoaded else { return nil }
        return BrowserHistoryStore.shared.entries.count
    }

    func sidebarFontSize() -> SettingsFontSize {
        // Reads the in-memory cache (kept current by config reloads) rather than
        // forcing a synchronous disk read on the main actor when Settings opens.
        SettingsFontSize(
            points: Double(GhosttyConfig.load().sidebarFontSize),
            minimum: CmuxGhosttyConfigSettingEditor.minSidebarFontSize,
            maximum: CmuxGhosttyConfigSettingEditor.maxSidebarFontSize,
            defaultValue: CmuxGhosttyConfigSettingEditor.defaultSidebarFontSize
        )
    }

    func terminalFontFamily() -> String {
        // See ``sidebarFontSize()`` — uses the cached config to avoid main-actor disk I/O.
        let family = GhosttyConfig.load().fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        return family.isEmpty ? CmuxGhosttyConfigSettingEditor.defaultTerminalFontFamily : family
    }

    func setTerminalFontFamily(_ family: String) async -> Bool {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? CmuxGhosttyConfigSettingEditor.defaultTerminalFontFamily : trimmed
        return await persistFontSetting(
            key: CmuxGhosttyConfigSettingEditor.terminalFontFamilyKey,
            value: value,
            reloadSource: "settings.appearance.terminalFontFamily"
        )
    }

    func terminalFontSize() -> SettingsFontSize {
        // See ``sidebarFontSize()`` — uses the cached config to avoid main-actor disk I/O.
        let editor = CmuxGhosttyConfigSettingEditor()
        return SettingsFontSize(
            points: editor.clampedTerminalFontSize(Double(GhosttyConfig.load().fontSize)),
            minimum: CmuxGhosttyConfigSettingEditor.minTerminalFontSize,
            maximum: CmuxGhosttyConfigSettingEditor.maxTerminalFontSize,
            defaultValue: CmuxGhosttyConfigSettingEditor.defaultTerminalFontSize
        )
    }

    func setTerminalFontSize(_ points: Double) async -> Bool {
        await persistFontSize(
            key: CmuxGhosttyConfigSettingEditor.terminalFontSizeKey,
            points: CmuxGhosttyConfigSettingEditor().clampedTerminalFontSize(points),
            reloadSource: "settings.appearance.terminalFontSize"
        )
    }

    func setSidebarFontSize(_ points: Double) async -> Bool {
        await persistFontSize(
            key: CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey,
            points: CmuxGhosttyConfigSettingEditor().clampedSidebarFontSize(points),
            reloadSource: "settings.sidebar.fontSize"
        )
    }

    func surfaceTabBarFontSize() -> SettingsFontSize {
        // See ``sidebarFontSize()`` — uses the cached config to avoid main-actor disk I/O.
        SettingsFontSize(
            points: Double(GhosttyConfig.load().surfaceTabBarFontSize),
            minimum: CmuxGhosttyConfigSettingEditor.minSurfaceTabBarFontSize,
            maximum: CmuxGhosttyConfigSettingEditor.maxSurfaceTabBarFontSize,
            defaultValue: CmuxGhosttyConfigSettingEditor.defaultSurfaceTabBarFontSize
        )
    }

    func setSurfaceTabBarFontSize(_ points: Double) async -> Bool {
        await persistFontSize(
            key: CmuxGhosttyConfigSettingEditor.surfaceTabBarFontSizeKey,
            points: CmuxGhosttyConfigSettingEditor().clampedSurfaceTabBarFontSize(points),
            reloadSource: "settings.terminal.tabBarFontSize"
        )
    }

    func formattedFontSize(_ points: Double) -> String {
        CmuxGhosttyConfigSettingEditor().formattedFontSize(points)
    }

    func mobilePairingStatus() -> MobilePairingStatusSnapshot? {
        Self.mobilePairingSnapshot(from: MobileHostService.shared.statusSnapshot())
    }

    func mobilePairingStatusUpdates() -> AsyncStream<MobilePairingStatusSnapshot> {
        AsyncStream { continuation in
            // Bridge the notification through a Sendable `Void` signal stream so
            // the non-Sendable `Notification` never crosses into the MainActor
            // drain task. Mirrors `UserDefaultsSettingsStore.values(for:)`.
            let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let observer = MobileHostStatusObserverToken(
                NotificationCenter.default.addObserver(
                    forName: .mobileHostStatusDidChange,
                    object: nil,
                    queue: nil
                ) { _ in
                    signalContinuation.yield(())
                }
            )
            let drainTask = Task { @MainActor in
                // Seed with the current status, then forward every change.
                continuation.yield(Self.mobilePairingSnapshot(from: MobileHostService.shared.statusSnapshot()))
                for await _ in signals {
                    if Task.isCancelled { break }
                    continuation.yield(Self.mobilePairingSnapshot(from: MobileHostService.shared.statusSnapshot()))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                drainTask.cancel()
                signalContinuation.finish()
                observer.remove()
            }
        }
    }

    /// Maps the host's ``MobileHostServiceStatus`` into the settings package's
    /// Foundation-only ``MobilePairingStatusSnapshot``. Static so the status
    /// stream's forwarding task does not retain this host bridge.
    private static func mobilePairingSnapshot(from status: MobileHostServiceStatus) -> MobilePairingStatusSnapshot {
        let routes = status.routes.compactMap { route -> MobilePairingRoute? in
            guard case let .hostPort(host, port) = route.endpoint else { return nil }
            return MobilePairingRoute(
                id: route.id,
                kindLabel: routeKindLabel(route.kind),
                host: host,
                port: port
            )
        }
        return MobilePairingStatusSnapshot(
            isRunning: status.isRunning,
            configuredPort: status.configuredPort,
            boundPort: status.port,
            usesEphemeralFallback: status.usesEphemeralFallback,
            activeConnectionCount: status.activeConnectionCount,
            routes: routes
        )
    }

    func mobilePairingDefaultDisplayName() -> String {
        // The Mac's system name, the pairing name used when no override is set.
        // Stable across override edits, so the placeholder never goes stale.
        Host.current().localizedName ?? ""
    }

    func applyMobilePairingPort(_ port: Int) async -> MobilePairingPortApplyResult {
        switch await MobileHostService.shared.applyConfiguredPort(port) {
        case .applied(let bound):
            return .applied(port: bound)
        case .portInUse:
            return .portInUse(requestedPort: port)
        case .savedWhileDisabled:
            return .savedForLater(port: port)
        case .invalid:
            return .invalid(requestedPort: port)
        }
    }

    /// Localized transport label for a pairing route shown in diagnostics.
    private static func routeKindLabel(_ kind: CmxAttachTransportKind) -> String {
        switch kind {
        case .tailscale:
            return String(localized: "settings.mobile.route.tailscale", defaultValue: "Tailscale")
        case .debugLoopback:
            return String(localized: "settings.mobile.route.loopback", defaultValue: "Loopback")
        case .iroh:
            return String(localized: "settings.mobile.route.iroh", defaultValue: "Iroh")
        case .websocket:
            return String(localized: "settings.mobile.route.websocket", defaultValue: "WebSocket")
        }
    }

    /// Writes a clamped font-size value to cmux's editable Ghostty config and
    /// triggers a live reload so open windows re-render at the new size.
    ///
    /// The disk write runs on the serial ``fontConfigWriter`` actor so the main
    /// actor is never blocked on file I/O during a slider drag or Reset tap, and
    /// rapid successive saves persist in submission order (last value wins). The
    /// reload then resumes on the main actor.
    ///
    /// - Returns: `true` on success, `false` if the write failed (a generic
    ///   warning is logged here; the Settings UI surfaces a save-failed message).
    private func persistFontSize(key: String, points: Double, reloadSource: String) async -> Bool {
        let formatted = CmuxGhosttyConfigSettingEditor().formattedFontSize(points)
        return await persistFontSetting(key: key, value: formatted, reloadSource: reloadSource)
    }

    private func persistFontSetting(key: String, value: String, reloadSource: String) async -> Bool {
        guard await fontConfigWriter.write(key: key, value: value) else {
            hostSettingsLogger.warning("failed to persist \(key, privacy: .public)")
            return false
        }
        GhosttyApp.shared.reloadConfiguration(source: reloadSource)
        return true
    }

}

/// Wraps the opaque observer returned by `NotificationCenter.addObserver` so the
/// `@Sendable` stream-termination closure can hold it for removal. Objective-C
/// doesn't model `Sendable`; the token is immutable and only hands the opaque
/// observer back to NotificationCenter's thread-safe removal API. CmuxSettings
/// has an identical internal token, which isn't `public`, so it's duplicated.
final class MobileHostStatusObserverToken: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    func remove() {
        NotificationCenter.default.removeObserver(token)
    }
}

/// Serializes cmux Ghostty config writes for font settings so rapid
/// successive saves apply in submission order instead of racing.
///
/// Settings controls fire saves from slider releases, picker changes, and Reset
/// taps. Routed through this single actor, the writes run one-at-a-time in
/// arrival order — each write is a full overwrite of the key, so the most
/// recently submitted value is always the one left on disk. The work runs off
/// the main actor.
private actor FontConfigWriter {
    /// Writes a single cmux-editable Ghostty config setting to disk.
    ///
    /// - Parameters:
    ///   - key: The Ghostty config key to write (e.g. `sidebar-font-size`).
    ///   - value: The already-formatted value to persist.
    /// - Returns: `true` if the write succeeded, `false` otherwise.
    func write(key: String, value: String) -> Bool {
        do {
            try ConfigSourceEnvironment.live().writeCmuxConfigSetting(key: key, value: value)
            return true
        } catch {
            return false
        }
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
