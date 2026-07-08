import AppKit
import CmuxSettings
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.cmux", category: "browser")

/// Opens `url` in the user's preferred external browser, as configured by
/// `browser.preferredExternalBrowser` in `~/.config/cmux/cmux.json`.
///
/// When the setting is empty (the default), behaviour is identical to calling
/// `NSWorkspace.shared.open(url)` directly. When set, cmux resolves the value
/// as a bundle ID or application display name and opens the URL in that app,
/// without touching the macOS system default browser.
///
/// Uses `NSWorkspace.open(_:configuration:)` — the fire-and-forget overload —
/// to avoid blocking the calling thread. This is safe to call from the main
/// thread and from WKNavigationDelegate callbacks.
@discardableResult
func cmuxOpenURLExternally(_ url: URL) -> Bool {
    let preferred = CmuxSettingsCatalog.shared.browser.preferredExternalBrowser.value
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !preferred.isEmpty else {
        return NSWorkspace.shared.open(url)
    }

    if let appURL = resolvePreferredBrowserURL(preferred) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg, completionHandler: nil)
        return true
    }

    logger.warning("cmuxOpenURLExternally: could not resolve preferred browser; falling back to system default")
    return NSWorkspace.shared.open(url)
}

/// Resolves a display name or bundle ID to an application file URL.
///
/// Lookup order:
/// 1. Bundle ID exact match via `NSWorkspace.urlForApplication(withBundleIdentifier:)`
/// 2. Running application by `localizedName` (fast path when the browser is already open)
/// 3. `/Applications/<name>.app` and `~/Applications/<name>.app` by display name
private func resolvePreferredBrowserURL(_ preferred: String) -> URL? {
    // 1. Bundle ID (e.g. "com.microsoft.edgemac")
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferred) {
        return url
    }

    // 2. Running app by localised name
    let lowerPreferred = preferred.lowercased()
    if let match = NSWorkspace.shared.runningApplications.first(where: {
        ($0.localizedName ?? "").lowercased() == lowerPreferred
    }), let bundleID = match.bundleIdentifier,
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return url
    }

    // 3. Display name in standard app directories
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
