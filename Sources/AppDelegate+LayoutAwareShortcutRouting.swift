import AppKit

extension AppDelegate {
    /// Whether a physical fallback for Close Tab must outrank the default
    /// Settings menu equivalent for this event.
    ///
    /// Character matching remains available for explicit punctuation bindings;
    /// the default binding is elevated only for its lower-confidence physical
    /// fallback, while an explicit Close Tab or Settings override remains
    /// authoritative.
    func shouldPreferPhysicalCloseTabFallbackOverSettings(event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              !KeyboardShortcutSettings.hasExplicitShortcutOverride(for: .openSettings),
              shortcutWhenClauseAllows(action: .closeTab, event: event) else {
            return false
        }

        let closeTab = KeyboardShortcutSettings.shortcut(for: .closeTab)
        let openSettings = KeyboardShortcutSettings.shortcut(for: .openSettings)
        guard !closeTab.isUnbound,
              !closeTab.hasChord,
              !openSettings.isUnbound,
              !openSettings.hasChord else {
            return false
        }

        guard let closeTabSource = closeTab.firstStroke.matchingSource(
            event: event,
            layoutCharacterProvider: shortcutLayoutCharacterProvider
        ),
        openSettings.firstStroke.matchingSource(
            event: event,
            layoutCharacterProvider: shortcutLayoutCharacterProvider
        ) != nil else {
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
