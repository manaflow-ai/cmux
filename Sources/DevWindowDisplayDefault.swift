import AppKit
import CmuxSettings
import CmuxSettingsUI

/// Shared, cross-tag default for which display new cmux DEV windows open on.
///
/// The value is a display's `localizedName` (e.g. `"LG HDR 4K"`), persisted in
/// the shared `cmux.json` under `app.devWindowDisplay` through ``CmuxSettings``.
///
/// It lives in `cmux.json` (a fixed path shared across bundle ids) rather than
/// per-bundle `UserDefaults` on purpose: every tagged dev build has its own
/// bundle id and therefore its own defaults domain, but we want one value
/// honored by *every* dev build and *every* launch path (`reload.sh`, an agent,
/// or cmd-clicking a Tag Opener link). The shared config file is the only store
/// all of those read. Release builds never apply it.
///
/// This is a thin wrapper over ``CmuxSettings/JSONConfigStore``: the
/// window-creation hook reads it synchronously via the store's `snapshotValue`
/// seam, and the Debug menu / CLI write through the store's async `set`.
enum DevWindowDisplayDefault {
    /// Legacy single-line file the value used to live in, before it moved into
    /// `cmux.json`. Read for migration and as a first-launch fallback, then
    /// ignored.
    static var legacyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/dev-window-display")
    }

    /// The trimmed display name in the legacy file, or `nil` when absent/empty.
    static func legacyFileName() -> String? {
        guard let raw = try? String(contentsOf: legacyFileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The configured display name from settings, or `nil` when unset/empty.
    /// Reads the store's synchronous snapshot, so it is safe to call on the
    /// main actor before any suspension point.
    static func current(_ runtime: SettingsRuntime) -> String? {
        let value = runtime.jsonStore
            .snapshotValue(for: runtime.catalog.app.devWindowDisplay)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Persist `name`, or clear the setting when `name` is `nil`/empty, through
    /// the shared settings store. Clearing removes the key (and prunes the empty
    /// parent), matching `cmux window default-display --clear`.
    static func set(_ name: String?, runtime: SettingsRuntime) async {
        let value = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            try? await runtime.jsonStore.reset(runtime.catalog.app.devWindowDisplay)
        } else {
            try? await runtime.jsonStore.set(value, for: runtime.catalog.app.devWindowDisplay)
        }
    }

    /// One-time best-effort migration of the pre-`cmux.json` file value into
    /// `app.devWindowDisplay`. No-op when the settings value is already set or
    /// the legacy file is absent. Leaves the legacy file untouched so an older
    /// build that still reads it keeps working too.
    static func migrateLegacyFileIfNeeded(runtime: SettingsRuntime) async {
        let existing = await runtime.jsonStore.value(for: runtime.catalog.app.devWindowDisplay)
        guard existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let name = legacyFileName() else { return }
        try? await runtime.jsonStore.set(name, for: runtime.catalog.app.devWindowDisplay)
    }

#if DEBUG
    /// Place a newly-created window on the configured display, if one is set and
    /// currently connected. No-ops otherwise. Repositions without raising or
    /// activating the window (it reuses the focus-safe placement helper), so it
    /// never steals focus. DEBUG-only: production cmux is never auto-moved.
    @MainActor
    static func applyToNewWindow(_ window: NSWindow) {
        guard let app = AppDelegate.shared,
              let runtime = app.settingsRuntime else { return }
        // Prefer the settings value; fall back to the legacy file so an existing
        // pre-migration default still places the very first window before the
        // async one-time migration has committed to cmux.json.
        guard let name = current(runtime) ?? legacyFileName(),
              let screen = app.screenMatching(name) else { return }
        app.repositionPreservingSize(window, onto: screen)
    }
#endif
}
