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
            if inheritsFocusHistoryOptOut(action) { return nil }
            let defaultShortcut = action.defaultShortcut
            return defaultShortcut.isUnbound ? nil : defaultShortcut
        }
        return shortcut.isUnbound ? nil : shortcut
    }

    /// Whether the user has stored their own value for `action` (settings file
    /// or legacy UserDefaults), as opposed to riding the factory default.
    /// User-stored values are a sparse overlay over compiled defaults; runtime
    /// routing uses this to keep a factory-default binding from shadowing a
    /// user-configured one on the same keystroke.
    static func isUserCustomized(_ action: Action) -> Bool {
        if settingsFileStore.override(for: action) != nil { return true }
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else { return false }
        return (try? JSONDecoder().decode(StoredShortcut.self, from: data)) != nil
    }

    /// Whether the user explicitly unbound `action` (an unbound marker stored in
    /// either layer), as opposed to never touching it.
    static func hasExplicitUnboundMarker(for action: Action) -> Bool {
        if let managedShortcut = settingsFileStore.override(for: action) {
            return managedShortcut.isUnbound
        }
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return false
        }
        return shortcut.isUnbound
    }

    /// Users who explicitly unbound Focus Back AND Focus Forward (the previously
    /// documented workaround to reclaim ⌘[ / ⌘] for browser panes) opted out of
    /// the focus-history verb on their keyboard; don't resurrect it through the
    /// global pair's factory default. Read-side only — never writes the user's
    /// config, and binding either global action explicitly always wins.
    private static func inheritsFocusHistoryOptOut(_ action: Action) -> Bool {
        switch action {
        case .focusHistoryBackGlobal, .focusHistoryForwardGlobal:
            return hasExplicitUnboundMarker(for: .focusHistoryBack)
                && hasExplicitUnboundMarker(for: .focusHistoryForward)
        default:
            return false
        }
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

        // Focus Back/Forward are gated to non-browser focus by their built-in
        // context, which a static menu equivalent would bypass (same hazard as
        // issue #5189, but for a built-in clause). The History menu shows the
        // always-available Global pair instead, so suppress the gated pair here.
        switch action {
        case .focusHistoryBack, .focusHistoryForward:
            return .unbound
        default:
            return shortcut(for: action)
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
