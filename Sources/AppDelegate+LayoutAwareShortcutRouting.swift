import AppKit

extension AppDelegate {
    /// Returns whether a default punctuation binding should yield its match to
    /// a Command-letter fallback from the same remapped physical key.
    ///
    /// The raw stroke matcher remains layout-semantic so explicit bindings such
    /// as `cmd+,` stay usable. Built-in action routing suppresses only implicit
    /// punctuation matches for this ambiguous event shape; the shared
    /// Close-Tab arbitration then selects the physical letter action.
    func shouldSuppressImplicitLayoutPunctuationShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Bool {
        // The observed menu collision is the built-in Settings Cmd+, item.
        // Keep other punctuation actions (including user-facing zoom/history
        // bindings) on the shared character path unless their own router adds
        // a deliberate precedence rule.
        guard action == .openSettings,
              !KeyboardShortcutSettings.hasExplicitShortcutOverride(for: action),
              shouldPreferPhysicalCloseTabFallbackOverSettings(event: event) else {
            return false
        }
        return true
    }

    /// Whether a Close Tab match must outrank a Settings menu equivalent.
    ///
    /// Character matching remains available for explicit punctuation bindings.
    /// The default binding is elevated only for its lower-confidence physical
    /// fallback, while an explicit Close Tab or Settings override remains
    /// authoritative. Stale menu equivalents are considered even when the
    /// current Settings binding was cleared or changed.
    func shouldPreferPhysicalCloseTabFallbackOverSettings(event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              ShortcutStroke.isCommandPunctuationFromPhysicalLetter(event),
              shortcutWhenClauseAllows(action: .closeTab, event: event) else {
            return false
        }

        let closeTab = KeyboardShortcutSettings.shortcut(for: .closeTab)
        let openSettings = KeyboardShortcutSettings.shortcut(for: .openSettings)
        let openSettingsIsExplicit = KeyboardShortcutSettings.hasExplicitShortcutOverride(for: .openSettings)
        guard !closeTab.isUnbound,
              !closeTab.hasChord else {
            return false
        }

        guard let closeTabSource = closeTab.firstStroke.matchingSource(
            event: event,
            layoutCharacterProvider: shortcutLayoutCharacterProvider
        ) else {
            return false
        }

        let currentSettingsMatches = !openSettings.hasChord &&
            openSettings.firstStroke.matchingSource(
                event: event,
                layoutCharacterProvider: shortcutLayoutCharacterProvider
            ) != nil
        if openSettingsIsExplicit && currentSettingsMatches {
            return false
        }

        let staleSettingsMatches = KeyboardShortcutSettings.Action.openSettings.defaultShortcut
            .firstStroke
            .matchingSource(
                event: event,
                layoutCharacterProvider: shortcutLayoutCharacterProvider
            ) != nil
        guard currentSettingsMatches || staleSettingsMatches else {
            return false
        }

        // The default Close Tab needs the physical rescue only when its
        // character plane is unusable. An explicit Close Tab binding is also
        // authoritative when it intentionally uses the same logical comma as
        // Settings on a remapped layout.
        return closeTabSource == .physicalFallback
            || KeyboardShortcutSettings.hasExplicitShortcutOverride(for: .closeTab)
    }
}
