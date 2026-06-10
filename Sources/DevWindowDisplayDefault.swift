import AppKit

/// Shared, cross-tag default for which display new cmux DEV windows open on.
///
/// The value is a display's `localizedName` (e.g. `"LG HDR 4K"`), stored as a
/// single line in `~/.config/cmux/dev-window-display`.
///
/// It lives in a fixed-path file rather than `UserDefaults` on purpose: every
/// tagged dev build has its own bundle id and therefore its own defaults domain,
/// but we want one value honored by *every* dev build and *every* launch path
/// (`reload.sh`, an agent, or cmd-clicking a Tag Opener link). A shared file is
/// the only store all of those read.
enum DevWindowDisplayDefault {
    /// Path to the shared setting file under the cmux config directory.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("dev-window-display", isDirectory: false)
    }

    /// The configured display name, or `nil` when unset or empty.
    static func read() -> String? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Persist `name`, or clear the setting when `name` is `nil`/empty.
    ///
    /// - Returns: `true` on success.
    @discardableResult
    static func write(_ name: String?) -> Bool {
        let url = fileURL
        let value = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if value.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try (value + "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            return false
        }
    }

#if DEBUG
    /// Place a newly-created window on the configured display, if one is set and
    /// currently connected. No-ops otherwise. Repositions without raising or
    /// activating the window (it reuses the focus-safe placement helper), so it
    /// never steals focus. DEBUG-only: production cmux is never auto-moved.
    @MainActor
    static func applyToNewWindow(_ window: NSWindow) {
        guard let name = read(),
              let app = AppDelegate.shared,
              let screen = app.screenMatching(name) else { return }
        app.repositionPreservingSize(window, onto: screen)
    }
#endif
}
