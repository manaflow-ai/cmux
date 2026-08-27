import CmuxSettings
import CmuxSettingsUI
import Foundation

extension KeyboardShortcutSettings {
    static func shortcutIfBound(for action: Action) -> StoredShortcut? {
        #if DEBUG
        shortcutLookupObserver?(action)
        #endif

        let managedBySettingsFile = settingsFileStore.isManagedByFile(action)
        let configuredShortcut = explicitlyConfiguredShortcut(for: action)
        let resolvedShortcut = effectivePersistedShortcut(
            configuredShortcut,
            for: action,
            managedBySettingsFile: managedBySettingsFile
        )

        // These defaults were introduced after older user settings could have
        // claimed their strokes. Route both through the shared resolver so an
        // existing explicit binding retains upgrade precedence.
        if action == .reopenClosedBrowserPanel
            || (action == .toggleVoiceDictation && !hasExplicitShortcutOverride(for: action)),
           resolvedShortcut == action.defaultShortcut,
           configuredShortcut != resolvedShortcut {
            return defaultShortcutResolvingLegacyConflicts(
                for: action,
                explicitlyConfiguredShortcut: explicitlyConfiguredShortcut(for:)
            )
        }

        return resolvedShortcut
    }

    static func defaultShortcutResolvingLegacyConflicts(
        for action: Action,
        explicitlyConfiguredShortcut: (Action) -> StoredShortcut?
    ) -> StoredShortcut? {
        guard let settingsAction = CmuxSettings.ShortcutAction(rawValue: action.rawValue) else {
            return action.defaultShortcut.isUnbound ? nil : action.defaultShortcut
        }
        return settingsAction.effectivePersistedShortcutResolvingLegacyConflicts(
            nil,
            explicitlyConfiguredShortcut: { settingsConfiguredAction in
                guard let configuredAction = Action(rawValue: settingsConfiguredAction.rawValue) else {
                    return nil
                }
                return explicitlyConfiguredShortcut(configuredAction)?.cmuxSettingsStoredShortcut
            },
            bindingsConflict: { proposed, settingsConfiguredAction, configured in
                guard let configuredAction = Action(rawValue: settingsConfiguredAction.rawValue) else {
                    return false
                }
                return configuredAction.conflicts(
                    with: StoredShortcut(cmuxSettingsStoredShortcut: proposed),
                    proposedAction: action,
                    configuredShortcut: StoredShortcut(cmuxSettingsStoredShortcut: configured)
                )
            }
        ).map(StoredShortcut.init(cmuxSettingsStoredShortcut:))
    }

    static func shortcut(for action: Action) -> StoredShortcut {
        shortcutIfBound(for: action) ?? .unbound
    }

    private static func explicitlyConfiguredShortcut(for action: Action) -> StoredShortcut? {
        if settingsFileStore.isManagedByFile(action) {
            return settingsFileStore.override(for: action)
        }
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(StoredShortcut.self, from: data)
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

    /// Whether the user persisted a binding for `action`, either in cmux.json
    /// or the legacy UserDefaults store. Used to preserve the precedence of an
    /// existing binding when a newly introduced default reuses its keystroke.
    static func hasExplicitShortcutOverride(for action: Action) -> Bool {
        settingsFileStore.override(for: action) != nil
            || UserDefaults.standard.object(forKey: action.defaultsKey) != nil
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

extension KeyboardShortcutSettings.Action {
    func tooltip(_ base: String) -> String {
        "\(base) (\(displayedShortcutString(for: KeyboardShortcutSettings.shortcut(for: self))))"
    }

    var usesNumberedDigitMatching: Bool {
        switch self {
        case .selectSurfaceByNumber, .selectWorkspaceByNumber:
            return true
        default:
            return false
        }
    }
}
