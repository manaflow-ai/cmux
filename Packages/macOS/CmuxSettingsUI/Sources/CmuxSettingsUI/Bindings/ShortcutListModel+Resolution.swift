import CmuxSettings

extension ShortcutListModel {
    /// The effective shortcut for `action`, using the runtime's JSON, legacy
    /// UserDefaults, then built-in precedence.
    func effective(for action: ShortcutAction) -> StoredShortcut? {
        let actionID = action.rawValue
        let candidate: StoredShortcut?
        if !managedBindingActionIDs.contains(actionID) {
            candidate = latestBindings[actionID] ?? legacyBindings[actionID]
        } else {
            candidate = bindings[actionID]
            if candidate == nil, action == .showHideAllWindows { return nil }
        }
        return action.effectivePersistedShortcut(
            candidate,
            normalizing: { shortcut in
                guard action.shortcutBindingPolicyResult(for: shortcut) == .accepted else {
                    return nil
                }
                if action == .showHideAllWindows,
                   !canRegisterSystemWideHotkey(shortcut) {
                    return nil
                }
                return shortcut.canonicalized()
            },
            conflictsWithReservedShortcut: { shortcut in
                guard action == .globalSearch,
                      let systemWideShortcut = effective(for: .showHideAllWindows) else {
                    return false
                }
                return ShortcutBindingConflict(
                    proposed: shortcut,
                    proposedUsesNumberedDigitMatching: action.usesNumberedDigitMatching,
                    configured: systemWideShortcut,
                    configuredUsesNumberedDigitMatching: false
                ).exists
            }
        )
    }

    /// Whether `action` is currently unbound but has a cached stroke available to
    /// restore (drives the X → restore button swap).
    func canRestore(for action: ShortcutAction) -> Bool {
        let effectiveShortcut = effective(for: action)
        let isUnbound = effectiveShortcut?.isUnbound ?? true
        return isUnbound && restoreShortcuts[action.rawValue] != nil
    }
}
