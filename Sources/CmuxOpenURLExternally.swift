import AppKit
import CmuxSettings
import os

nonisolated private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.cmux", category: "browser")

/// Opens external URLs in the user's preferred browser, as configured by
/// `browser.preferredExternalBrowser` in `~/.config/cmux/cmux.json`.
///
/// Construct an instance and call `open(_:)`. The preferred-browser lookup is
/// intentionally re-read at call time (not cached) so config changes take effect
/// without restarting the app.
struct ExternalBrowserOpener {

    /// Opens `url` in the configured preferred browser, falling back to the
    /// system default when the setting is empty or the app cannot be resolved.
    ///
    /// Uses `NSWorkspace.open(_:withApplicationAt:configuration:completionHandler:)`
    /// — the fire-and-forget overload — so this is safe to call from any thread,
    /// including the main thread and WKNavigationDelegate callbacks.
    @discardableResult
    func open(_ url: URL) -> Bool {
        let preferred = SettingCatalog().browser.preferredExternalBrowser.value(in: .standard)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !preferred.isEmpty else {
            return NSWorkspace.shared.open(url)
        }

        if let appURL = resolvePreferredBrowserURL(preferred) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, error in
                if let error {
                    logger.error("Failed to open URL in preferred browser: \(error.localizedDescription, privacy: .public)")
                }
            }
            return true
        }

        logger.warning("ExternalBrowserOpener: could not resolve preferred browser; falling back to system default")
        return NSWorkspace.shared.open(url)
    }

    /// Resolves a display name or bundle ID to an application file URL.
    ///
    /// Lookup order:
    /// 1. Bundle ID exact match via `NSWorkspace.urlForApplication(withBundleIdentifier:)`
    /// 2. Running application by `localizedName` (fast path when the browser is already open)
    /// 3. `/Applications/<name>.app` and `~/Applications/<name>.app` by display name
    private func resolvePreferredBrowserURL(_ preferred: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferred) {
            return url
        }

        let lowerPreferred = preferred.lowercased()
        if let match = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").lowercased() == lowerPreferred
        }), let bundleID = match.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }

        let appDirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Applications"),
        ]
        for dir in appDirs {
            let candidate = dir.appendingPathComponent("\(preferred).app")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}

