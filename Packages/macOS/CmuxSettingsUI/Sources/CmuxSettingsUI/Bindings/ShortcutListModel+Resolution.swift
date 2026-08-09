import CmuxSettings

extension ShortcutListModel {
    /// The effective shortcut for `action`, using the runtime's JSON, legacy
    /// UserDefaults, then built-in precedence.
    func effective(for action: ShortcutAction) -> StoredShortcut? {
        let candidate = explicitlyConfiguredShortcut(for: action)
        if candidate == nil,
           managedBindingActionIDs.contains(action.rawValue),
           action == .showHideAllWindows {
            return nil
        }
        return action.effectivePersistedShortcutResolvingLegacyConflicts(
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
            },
            explicitlyConfiguredShortcut: explicitlyConfiguredShortcut(for:),
            bindingsConflict: { proposed, configuredAction, configured in
                guard ShortcutWhenClause.bindingsCollide(
                    whenOverrideClauses[action.rawValue] ?? action.defaultFocusWhenClause,
                    lhsHasPriority: action.hasPriorityShortcutRouting,
                    whenOverrideClauses[configuredAction.rawValue]
                        ?? configuredAction.defaultFocusWhenClause,
                    rhsHasPriority: configuredAction.hasPriorityShortcutRouting
                ) else {
                    return false
                }
                return ShortcutBindingConflict(
                    proposed: proposed,
                    proposedUsesNumberedDigitMatching: action.usesNumberedDigitMatching,
                    configured: configured,
                    configuredUsesNumberedDigitMatching:
                        configuredAction.usesNumberedDigitMatching
                ).exists
            }
        )
    }

    private func explicitlyConfiguredShortcut(for action: ShortcutAction) -> StoredShortcut? {
        let actionID = action.rawValue
        if managedBindingActionIDs.contains(actionID) {
            return bindings[actionID]
        }
        return latestBindings[actionID] ?? legacyBindings[actionID]
    }

    /// Whether `action` is currently unbound but has a cached stroke available to
    /// restore (drives the X → restore button swap).
    func canRestore(for action: ShortcutAction) -> Bool {
        let effectiveShortcut = effective(for: action)
        let isUnbound = effectiveShortcut?.isUnbound ?? true
        return isUnbound && restoreShortcuts[action.rawValue] != nil
    }
}
