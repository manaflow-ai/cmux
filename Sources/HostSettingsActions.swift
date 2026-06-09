import AppKit
import CMUXMobileCore
import CmuxSettingsUI
import Foundation
import OSLog
import SwiftUI

private let hostSettingsLogger = Logger(subsystem: "com.cmuxterm.app", category: "Settings")

/// App-side implementation of the package's `SettingsHostActions`
/// protocol. Routes UI-triggered actions to the existing host
/// services (`BrowserHistoryStore`, `BrowserDataImportCoordinator`,
/// `TerminalNotificationStore`, etc.) so the package doesn't need to
/// depend on them directly.
@MainActor
final class HostSettingsActions: SettingsHostActions {
    private let configFileURL: URL

    /// Serializes font-size config writes so rapid slider saves persist in order.
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
        // Honor the user's configured editor (`preferredEditorCommand`),
        // falling back to the OS default. Opening the config file directly
        // through `NSWorkspace.shared.open` would route to the default
        // `.json` handler and ignore the cmux setting.
        PreferredEditorSettings.open(configFileURL)
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

    func setSidebarFontSize(_ points: Double) async -> Bool {
        await persistFontSize(
            key: CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey,
            points: CmuxGhosttyConfigSettingEditor.clampedSidebarFontSize(points),
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
            points: CmuxGhosttyConfigSettingEditor.clampedSurfaceTabBarFontSize(points),
            reloadSource: "settings.terminal.tabBarFontSize"
        )
    }

    func formattedFontSize(_ points: Double) -> String {
        CmuxGhosttyConfigSettingEditor.formattedFontSize(points)
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
        let formatted = CmuxGhosttyConfigSettingEditor.formattedFontSize(points)
        guard await fontConfigWriter.write(key: key, value: formatted) else {
            hostSettingsLogger.warning("failed to persist \(key, privacy: .public)")
            return false
        }
        GhosttyApp.shared.reloadConfiguration(source: reloadSource)
        return true
    }

    // MARK: - Background image theme

    func chooseBackgroundImagePath() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "settings.backgroundImage.choose", defaultValue: "Choose")
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func availableImageThemePresets() -> [ImageThemePresetInfo] {
        ImageThemePresets.all.map {
            ImageThemePresetInfo(key: $0.key, name: $0.name, opacity: $0.opacity)
        }
    }

    func applyImageThemePreset(_ key: String) async -> String? {
        guard let preset = ImageThemePresets.preset(for: key) else { return nil }
        // Decode the bundled asset to JPEG on the main actor (AppKit), then run
        // the disk writes through the serial mutator so rapid preset switches
        // apply in order and Settings stays responsive.
        let imageData = ImageThemePresets.encodedImageData(for: preset)
        do {
            let imagePath = try await ImageThemeMutator.shared.perform {
                try ImageThemePresets.write(preset: preset, imageData: imageData)
            }
            GhosttyApp.shared.reloadConfiguration(source: "settings.backgroundImage.preset.\(key)")
            return imagePath
        } catch {
            // error.localizedDescription may contain home-directory paths; keep private.
            hostSettingsLogger.error("apply image theme failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func clearBackgroundImageTheme() async -> Bool {
        do {
            try await ImageThemeMutator.shared.perform {
                try ImageThemePresets.removeManagedBlock()
            }
            GhosttyApp.shared.reloadConfiguration(source: "settings.backgroundImage.clear")
            return true
        } catch {
            hostSettingsLogger.error("clear image theme failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}

/// Serializes image-theme config mutations so concurrent apply/clear actions
/// (e.g. rapid preset clicks) run one at a time in submission order, keeping the
/// Ghostty config and the persisted settings last-write-wins rather than
/// dependent on detached-task completion order.
private actor ImageThemeMutator {
    static let shared = ImageThemeMutator()

    func perform<T: Sendable>(_ work: @Sendable () throws -> T) async rethrows -> T {
        try work()
    }
}

/// Bundled image themes ported from Warp. Each preset pairs a bundled background
/// image with a 16-color palette and a fully transparent terminal background
/// (so the window image shows uniformly across the terminal and chrome), applied
/// via a managed block in the user's Ghostty config.
enum ImageThemePresets {
    /// One bundled image theme: its display name, bundled asset, on-disk
    /// filename, renderer opacity, and Ghostty colors.
    struct Preset {
        /// Stable identifier persisted in settings (snake_case).
        let key: String
        /// Display name shown in the preset menu (a Warp theme proper noun).
        let name: String
        /// Asset-catalog image name (e.g. "SolarFlareBackground").
        let assetName: String
        /// Stable on-disk filename under `~/.config/cmux/backgrounds/`.
        let filename: String
        /// Image opacity 0–1 used by the renderer (matches Warp's per-theme value).
        let opacity: Double
        /// Ghostty `background` hex (no `#`).
        let background: String
        /// Ghostty `foreground` hex (no `#`).
        let foreground: String
        /// 16 Ghostty palette hex values (no `#`), indices 0–15.
        let palette: [String]
    }

    /// Errors surfaced from theme apply/clear so the caller can report failure
    /// instead of silently leaving a half-applied theme.
    enum ThemeError: Error {
        case assetEncodingFailed(String)
        case fileWriteFailed(String)
    }

    static let all: [Preset] = [
        Preset(key: "solar_flare", name: "Solar Flare", assetName: "SolarFlareBackground", filename: "solarflare_bg.jpg", opacity: 0.2,
               background: "1b1c18", foreground: "dde6ee",
               palette: ["2e333d","d66060","64af86","caa358","5c80b2","b766a1","8069a1","f0f4f7","37404a","eb8282","64af86","caa358","5c80b2","b766a1","8069a1","ffffff"]),
        Preset(key: "phenomenon", name: "Phenomenon", assetName: "PhenomenonBackground", filename: "phenomenon_bg.jpg", opacity: 1.0,
               background: "121212", foreground: "faf9f6",
               palette: ["121212","d22d1e","1ca05a","e5a01a","3780e9","bf409d","799c92","faf9f6","292929","ae756f","789b88","bd9f65","6f839f","a57899","bfc5c3","ffffff"]),
        Preset(key: "jellyfish", name: "Jellyfish", assetName: "JellyfishBackground", filename: "jellyfish_bg.jpg", opacity: 0.3,
               background: "1b1718", foreground: "ffffff",
               palette: ["616161","ff8272","b4fa72","fefdc2","a5d5fe","ff8ffd","d0d1fe","f1f1f1","8e8e8e","ffc4bd","d6fcb9","fefdd5","c1e3fe","ffb1fe","e5e6fe","feffff"]),
        Preset(key: "koi", name: "Koi", assetName: "KoiBackground", filename: "koi_bg.jpg", opacity: 0.3,
               background: "211719", foreground: "ffffff",
               palette: ["616161","ff8272","b4fa72","fefdc2","a5d5fe","ff8ffd","d0d1fe","f1f1f1","8e8e8e","ffc4bd","d6fcb9","fefdd5","c1e3fe","ffb1fe","e5e6fe","feffff"]),
        Preset(key: "leafy", name: "Leafy", assetName: "LeafyBackground", filename: "leafy_bg.jpg", opacity: 0.3,
               background: "000000", foreground: "ffffff",
               palette: ["616161","ff8272","b4fa72","fefdc2","a5d5fe","ff8ffd","d0d1fe","f1f1f1","8e8e8e","ffc4bd","d6fcb9","fefdd5","c1e3fe","ffb1fe","e5e6fe","feffff"]),
        Preset(key: "marble", name: "Marble", assetName: "MarbleBackground", filename: "marble_bg.jpg", opacity: 0.5,
               background: "e3e3e3", foreground: "000000",
               palette: ["212121","c30771","10a778","a89c14","008ec4","523c79","20a5ba","e0e0e0","212121","fb007a","5fd7af","f3e430","20bbfc","6855de","4fb8cc","f1f1f1"]),
        Preset(key: "pink_city", name: "Pink City", assetName: "PinkCityBackground", filename: "pink_city_bg.jpg", opacity: 0.4,
               background: "fbeff6", foreground: "000000",
               palette: ["212121","c30771","10a778","a89c14","008ec4","523c79","20a5ba","e0e0e0","212121","fb007a","5fd7af","f3e430","20bbfc","6855de","4fb8cc","f1f1f1"]),
        Preset(key: "snowy", name: "Snowy", assetName: "SnowyBackground", filename: "snowy_bg.jpg", opacity: 0.2,
               background: "ffffff", foreground: "000000",
               palette: ["212121","c30771","10a778","a89c14","008ec4","523c79","20a5ba","e0e0e0","212121","fb007a","5fd7af","f3e430","20bbfc","6855de","4fb8cc","f1f1f1"]),
        Preset(key: "red_rock", name: "Red Rock", assetName: "RedRockBackground", filename: "red_rock_bg.jpg", opacity: 0.3,
               background: "211719", foreground: "ffffff",
               palette: ["616161","ff8272","b4fa72","fefdc2","a5d5fe","ff8ffd","d0d1fe","f1f1f1","8e8e8e","ffc4bd","d6fcb9","fefdd5","c1e3fe","ffb1fe","e5e6fe","feffff"]),
        Preset(key: "dark_city", name: "Dark City", assetName: "DarkCityBackground", filename: "dark_city_bg.jpg", opacity: 0.2,
               background: "01181f", foreground: "ffffff",
               palette: ["616161","ff8272","b4fa72","fefdc2","a5d5fe","ff8ffd","d0d1fe","f1f1f1","8e8e8e","ffc4bd","d6fcb9","fefdd5","c1e3fe","ffb1fe","e5e6fe","feffff"]),
    ]

    /// Looks up a preset by its persisted key.
    static func preset(for key: String) -> Preset? {
        all.first { $0.key == key }
    }

    private static let blockStart = "# cmux image theme start"
    private static let blockEnd = "# cmux image theme end"

    private static var ghosttyConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/ghostty/config")
    }

    private static func backgroundImageURL(filename: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/cmux/backgrounds/\(filename)")
    }

    /// Decodes the preset's bundled asset to JPEG `Data` on the main actor
    /// (AppKit `NSImage`). Returns nil if the bundled image is already
    /// materialized on disk (no re-encode needed) or cannot be decoded.
    @MainActor
    static func encodedImageData(for preset: Preset) -> Data? {
        if FileManager.default.fileExists(atPath: backgroundImageURL(filename: preset.filename).path) {
            return nil
        }
        guard let image = NSImage(named: preset.assetName),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        else {
            return nil
        }
        return jpeg
    }

    /// Writes the materialized image (if `imageData` is provided) and the managed
    /// Ghostty palette block to disk. Safe to call off the main actor. Returns the
    /// on-disk image path.
    static func write(preset: Preset, imageData: Data?) throws -> String {
        let destinationURL = backgroundImageURL(filename: preset.filename)
        let fileManager = FileManager.default
        if let imageData {
            do {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try imageData.write(to: destinationURL)
            } catch {
                throw ThemeError.fileWriteFailed("background image: \(error.localizedDescription)")
            }
        } else if !fileManager.fileExists(atPath: destinationURL.path) {
            throw ThemeError.assetEncodingFailed(preset.assetName)
        }
        try writeGhosttyBlock(preset)
        return destinationURL.path
    }

    /// Idempotently writes the preset's palette + a fully transparent terminal
    /// background as a managed block in `~/.config/ghostty/config`.
    static func writeGhosttyBlock(_ preset: Preset) throws {
        var lines = [
            blockStart,
            "background = \(preset.background)",
            "foreground = \(preset.foreground)",
            "background-opacity = 0.0",
        ]
        for (index, hex) in preset.palette.enumerated() {
            lines.append("palette = \(index)=#\(hex)")
        }
        lines.append(blockEnd)
        let block = lines.joined(separator: "\n")

        let url = ghosttyConfigURL
        // A missing file is fine (start fresh); a file that exists but can't be
        // read must NOT be treated as empty or we'd clobber the user's config.
        let existing = try readExistingConfig(at: url)
        let stripped = removingManagedBlockText(from: existing)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let next = stripped.isEmpty ? "\(block)\n" : "\(stripped)\n\n\(block)\n"
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try next.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ThemeError.fileWriteFailed("ghostty config: \(error.localizedDescription)")
        }
    }

    /// Removes the managed image-theme block from the Ghostty config, reverting
    /// palette/background to the user's own directives. Safe to call off the main
    /// actor.
    static func removeManagedBlock() throws {
        let url = ghosttyConfigURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Exists but unreadable → surface as failure, don't silently no-op and
        // leave the managed block behind.
        let existing = try readExistingConfig(at: url)
        let stripped = removingManagedBlockText(from: existing)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if stripped.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try (stripped + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            throw ThemeError.fileWriteFailed("ghostty config: \(error.localizedDescription)")
        }
    }

    /// Reads the existing Ghostty config. Returns "" if the file does not exist,
    /// but throws if it exists and cannot be read — so callers never overwrite an
    /// unreadable config with just the managed block.
    private static func readExistingConfig(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ThemeError.fileWriteFailed("read ghostty config: \(error.localizedDescription)")
        }
    }

    private static func removingManagedBlockText(from contents: String) -> String {
        // Also strip the legacy "# cmux solar flare" block from earlier builds.
        var result = contents
        for (start, end) in [(blockStart, blockEnd), ("# cmux solar flare start", "# cmux solar flare end")] {
            let pattern = "(?ms)\\n?" + NSRegularExpression.escapedPattern(for: start)
                + "\\n.*?\\n" + NSRegularExpression.escapedPattern(for: end) + "\\n?"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }
        return result
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

/// Serializes cmux Ghostty config writes for the font-size settings so rapid
/// successive saves apply in submission order instead of racing.
///
/// The Settings sliders fire a save on every release and Reset tap. Routed
/// through this single actor, the writes run one-at-a-time in arrival order —
/// each write is a full overwrite of the key, so the most recently submitted
/// value is always the one left on disk. The work runs off the main actor.
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
