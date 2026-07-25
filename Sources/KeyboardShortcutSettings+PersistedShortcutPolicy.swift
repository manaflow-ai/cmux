import CmuxSettings

/// Bridges the app target's legacy shortcut representation into the shared
/// action-owned persistence policy.
extension KeyboardShortcutSettings.Action {
    func shortcutBindingPolicyRejection(
        for shortcut: StoredShortcut
    ) -> KeyboardShortcutSettings.ShortcutRecordingRejection? {
        guard let settingsAction = CmuxSettings.ShortcutAction(rawValue: rawValue) else {
            return nil
        }

        switch settingsAction.shortcutBindingPolicyResult(
            for: shortcut.cmuxSettingsStoredShortcut
        ) {
        case .accepted:
            return nil
        case .bareFirstStrokeNotAllowed:
            return self == .showHideAllWindows
                ? .systemWideHotkeyRequiresModifier
                : .bareKeyNotAllowed
        case .chordNotAllowed, .systemDefinedMediaKeyNotAllowed:
            return .reservedBySystem
        }
    }
}

extension KeyboardShortcutSettings {
    /// Resolves one persistence layer's candidate, falling back to a valid
    /// built-in default when the candidate cannot execute.
    static func effectivePersistedShortcut(
        _ candidate: StoredShortcut?,
        for action: Action
    ) -> StoredShortcut? {
        if let candidate {
            if candidate.isUnbound {
                return nil
            }
            if let normalized = normalizedEffectiveShortcut(candidate, for: action) {
                return normalized
            }
        }

        let defaultShortcut = action.defaultShortcut
        guard !defaultShortcut.isUnbound else { return nil }
        return normalizedEffectiveShortcut(defaultShortcut, for: action)
    }

    private static func normalizedEffectiveShortcut(
        _ shortcut: StoredShortcut,
        for action: Action
    ) -> StoredShortcut? {
        guard case let .accepted(normalized) = action
            .resolvedRecordedShortcutIgnoringConflicts(
                shortcut,
                checkingSystemWideConflicts: false
            ),
            !conflictsWithConfiguredSystemWideHotkey(normalized, action: action) else {
            return nil
        }
        return normalized
    }

    private static func conflictsWithConfiguredSystemWideHotkey(
        _ shortcut: StoredShortcut,
        action: Action
    ) -> Bool {
        guard action == .globalSearch,
              let proposedPrefix = shortcut.firstStroke.carbonHotKeyRegistration,
              let systemWideHotkey = SystemWideHotkeySettings.shortcut()
                .firstStroke.carbonHotKeyRegistration else {
            return false
        }
        return proposedPrefix == systemWideHotkey
    }
}

private extension StoredShortcut {
    var cmuxSettingsStoredShortcut: CmuxSettings.StoredShortcut {
        CmuxSettings.StoredShortcut(
            first: firstStroke.cmuxSettingsShortcutStroke,
            second: secondStroke?.cmuxSettingsShortcutStroke
        )
    }
}

private extension ShortcutStroke {
    var cmuxSettingsShortcutStroke: CmuxSettings.ShortcutStroke {
        CmuxSettings.ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control,
            keyCode: keyCode
        )
    }
}
