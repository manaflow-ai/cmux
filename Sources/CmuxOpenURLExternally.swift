import AppKit
import CmuxSettings

/// Opens `url` in the user's preferred external browser, as configured by
/// `browser.preferredExternalBrowser` in `~/.config/cmux/cmux.json`.
///
/// When the setting is empty (the default), behaviour is identical to calling
/// `NSWorkspace.shared.open(url)` directly.  When set, cmux attempts to
/// resolve the value as either a bundle ID or an application display name and
/// opens the URL in that application, without touching the system default
/// browser setting.
@discardableResult
func cmuxOpenURLExternally(_ url: URL) -> Bool {
    let preferred = CmuxSettingsCatalog.shared.browser.preferredExternalBrowser.value
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !preferred.isEmpty else {
        return NSWorkspace.shared.open(url)
    }

    // 1. Try bundle ID (e.g. "com.microsoft.edgemac")
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferred) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        var opened = false
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, _ in
            opened = true
            sem.signal()
        }
        sem.wait()
        return opened
    }

    // 2. Match by display name against all installed apps the workspace knows about.
    //    Check running apps first (fast path), then fall back to a Spotlight lookup.
    let lowerPreferred = preferred.lowercased()

    let runningMatch = NSWorkspace.shared.runningApplications.first {
        ($0.localizedName ?? "").lowercased() == lowerPreferred
    }
    if let bundleID = runningMatch?.bundleIdentifier,
       let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        var opened = false
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, _ in
            opened = true
            sem.signal()
        }
        sem.wait()
        return opened
    }

    // 3. Ask NSWorkspace to find an app by display name via file URL heuristic.
    //    NSWorkspace.urlForApplication(toOpen:) matches by UTI, not name, so we
    //    use LSCopyApplicationURLsForBundleIdentifier-style lookup via the app
    //    directories instead.
    let appDirs = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "\(NSHomeDirectory())/Applications"),
    ]
    for dir in appDirs {
        let candidate = dir.appendingPathComponent("\(preferred).app")
        if FileManager.default.fileExists(atPath: candidate.path) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            var opened = false
            let sem = DispatchSemaphore(value: 0)
            NSWorkspace.shared.open([url], withApplicationAt: candidate, configuration: cfg) { _, _ in
                opened = true
                sem.signal()
            }
            sem.wait()
            return opened
        }
    }

    // 4. System default browser fallback — preferred app was not found.
    NSLog("cmuxOpenURLExternally: could not resolve preferred browser \"%@\"; falling back to system default", preferred)
    return NSWorkspace.shared.open(url)
}
