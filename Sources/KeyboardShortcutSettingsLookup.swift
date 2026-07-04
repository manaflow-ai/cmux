import CmuxSettings
import CmuxSettingsUI
import Foundation

extension KeyboardShortcutSettings {
    static func shortcutIfBound(for action: Action) -> StoredShortcut? {
        #if DEBUG
        shortcutLookupObserver?(action)
        #endif

        if let managedShortcut = settingsFileStore.override(for: action) {
            return managedShortcut.isUnbound ? nil : managedShortcut
        }

        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            let defaultShortcut = action.defaultShortcut
            return defaultShortcut.isUnbound ? nil : defaultShortcut
        }
        return shortcut.isUnbound ? nil : shortcut
    }

    static func shortcut(for action: Action) -> StoredShortcut {
        shortcutIfBound(for: action) ?? .unbound
    }

    static func menuShortcut(for action: Action) -> StoredShortcut {
        guard !KeyboardShortcutRecorderActivity.isAnyRecorderActive,
              !RecorderHostButton.isActivelyRecording else {
            return .unbound
        }

        // A static menu key equivalent fires regardless of focus, which would
        // bypass a configured `shortcuts.when` clause (e.g. fire a sidebar-gated
        // closeTab via the File menu while a terminal is focused). When the user
        // has explicitly scoped an action with `when`, drop its menu equivalent so
        // the context-gated keyDown handler is the sole dispatcher (issue #5189).
        // Built-in default contexts are left alone to preserve existing menu badges.
        if hasRestrictingConfiguredWhenClause(for: action) {
            return .unbound
        }

        let shortcut = shortcut(for: action)
        switch action {
        case .browserBack
            where !shortcut.isUnbound && shortcut == KeyboardShortcutSettings.shortcut(for: .focusHistoryBack):
            return .unbound
        case .browserForward
            where !shortcut.isUnbound && shortcut == KeyboardShortcutSettings.shortcut(for: .focusHistoryForward):
            return .unbound
        default:
            return shortcut
        }
    }

    static func isManagedBySettingsFile(_ action: Action) -> Bool {
        settingsFileStore.isManagedByFile(action)
    }

    /// The effective focus predicate gating `action`: the `shortcuts.when`
    /// override from cmux.json if present, otherwise the action's built-in
    /// ``KeyboardShortcutSettings/Action/shortcutContext`` expressed as a
    /// ``ShortcutWhenClause``. Drives both runtime availability and conflict
    /// detection so the same keystroke can be context-routed.
    static func effectiveWhenClause(for action: Action) -> ShortcutWhenClause {
        settingsFileStore.whenClause(for: action) ?? action.shortcutContext.defaultWhenClause
    }

    /// Whether `action` has an explicit `shortcuts.when` override that restricts focus.
    static func hasRestrictingConfiguredWhenClause(for action: Action) -> Bool {
        guard let clause = settingsFileStore.whenClause(for: action) else {
            return false
        }
        return clause != .always
    }

    static func unbindShortcut(for action: Action) {
        setShortcut(.unbound, for: action)
    }

    static func settingsFileManagedSubtitle(for action: Action) -> String? {
        guard isManagedBySettingsFile(action) else { return nil }
        return String(localized: "settings.shortcuts.managedByFile", defaultValue: "Managed in cmux.json")
    }

    /// The bonsplit surface tab bar renders its Cmd/Ctrl-hold shortcut hint
    /// (`⌘1`, `⌃2`, …) by reading the surface-number shortcut straight from
    /// `UserDefaults.standard` under `selectSurfaceByNumber.defaultsKey` (see
    /// `TabControlShortcutSettings` in vendor/bonsplit). That raw read bypasses
    /// cmux's canonical resolution in ``shortcutIfBound(for:)`` — a `cmux.json`
    /// override or the in-app Settings recorder both persist to the settings
    /// file, not to that UserDefaults key — so after the user rebinds the
    /// surface shortcut (e.g. from `⌥` to `⌘`) the tab-bar hint keeps showing
    /// the stale modifier while the actual keystroke already uses the new one.
    ///
    /// Mirror the fully-resolved shortcut into that key so the hint always
    /// matches the shortcut cmux actually dispatches. Writing the resolved value
    /// is a no-op for the pure-UserDefaults path (it already holds it) and, for
    /// the file-managed path, leaves ``shortcutIfBound(for:)`` unchanged because
    /// the settings-file override still wins at a higher priority.
    static func syncSurfaceNumberShortcutMirrorForTabBarHint(defaults: UserDefaults = .standard) {
        let action = Action.selectSurfaceByNumber
        let resolved = shortcut(for: action)
        guard let data = try? JSONEncoder().encode(resolved) else { return }
        if defaults.data(forKey: action.defaultsKey) != data {
            defaults.set(data, forKey: action.defaultsKey)
        }
    }

}
