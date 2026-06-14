import CmuxSettings
import CmuxSettingsUI
import Foundation

extension KeyboardShortcutSettings {
    private static func configuredShortcutIfPresent(for action: Action) -> (exists: Bool, shortcut: StoredShortcut?) {
        if let managedShortcut = settingsFileStore.override(for: action) {
            return (true, managedShortcut.isUnbound ? nil : managedShortcut)
        }

        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return (false, nil)
        }
        return (true, shortcut.isUnbound ? nil : shortcut)
    }

    private static func legacySurfaceSelectionShortcutIfPresent(for action: Action) -> (exists: Bool, shortcut: StoredShortcut?) {
        guard let digit = action.surfaceSelectionDigit else { return (false, nil) }

        let legacy = configuredShortcutIfPresent(for: .selectSurfaceByNumber)
        guard legacy.exists else { return (false, nil) }
        guard var shortcut = legacy.shortcut else { return (true, nil) }

        // Preserve legacy modifiers and stroke shape: chorded shortcuts replace the
        // second-stroke digit, while single-stroke shortcuts replace the primary key.
        if shortcut.hasChord {
            shortcut.chordKey = String(digit)
        } else {
            shortcut.key = String(digit)
        }
        return (true, shortcut)
    }

    static func shortcutIfBound(for action: Action) -> StoredShortcut? {
        #if DEBUG
        shortcutLookupObserver?(action)
        #endif

        let configured = configuredShortcutIfPresent(for: action)
        if configured.exists {
            return configured.shortcut
        }

        let legacySurfaceSelection = legacySurfaceSelectionShortcutIfPresent(for: action)
        if legacySurfaceSelection.exists {
            return legacySurfaceSelection.shortcut
        }

        let defaultShortcut = action.defaultShortcut
        return defaultShortcut.isUnbound ? nil : defaultShortcut
    }

    static func shortcut(for action: Action) -> StoredShortcut {
        shortcutIfBound(for: action) ?? .unbound
    }

    static func hasExplicitShortcutConfiguration(for action: Action) -> Bool {
        configuredShortcutIfPresent(for: action).exists
    }

    static func inheritsLegacySurfaceSelectionConfiguration(for action: Action) -> Bool {
        guard action.surfaceSelectionDigit != nil else { return false }
        if configuredShortcutIfPresent(for: action).exists {
            return false
        }
        return legacySurfaceSelectionShortcutIfPresent(for: action).exists
    }

    static func effectiveWhenClauseAction(for action: Action) -> Action {
        inheritsLegacySurfaceSelectionConfiguration(for: action) ? .selectSurfaceByNumber : action
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

}
