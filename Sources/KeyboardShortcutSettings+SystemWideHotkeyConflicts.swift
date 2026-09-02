import Foundation

/// System-wide shortcut conflict helpers extracted from `KeyboardShortcutSettings.swift`, which sits at its file-length budget.
extension KeyboardShortcutSettings {
    /// Resolves one action for conflict comparison without consulting any
    /// other action's effective binding. Conflict validation is intentionally
    /// a graph walk over these action-local snapshots; using `shortcut(for:)`
    /// here would re-enter system-wide reservation lookup and recursively
    /// initialize its static state.
    static func conflictResolutionShortcut(for action: Action) -> StoredShortcut {
        let managedBySettingsFile = settingsFileStore.isManagedByFile(action)
        let candidate: StoredShortcut? = if managedBySettingsFile {
            settingsFileStore.override(for: action)
        } else if let data = UserDefaults.standard.data(forKey: action.defaultsKey) {
            try? JSONDecoder().decode(StoredShortcut.self, from: data)
        } else {
            nil
        }

        if managedBySettingsFile,
           candidate == nil,
           action == .showHideAllWindows {
            return .unbound
        }
        if let candidate {
            if candidate.isUnbound {
                return .unbound
            }
            if case let .accepted(normalized) = action
                .resolvedRecordedShortcutIgnoringConflicts(
                    candidate,
                    checkingSystemWideConflicts: false
                ) {
                return normalized
            }
            // Show/Hide must fail closed for an invalid explicit binding; it
            // must never silently register its system-wide default instead.
            if action == .showHideAllWindows {
                return .unbound
            }
        }

        guard case let .accepted(normalizedDefault) = action
            .resolvedRecordedShortcutIgnoringConflicts(
                action.defaultShortcut,
                checkingSystemWideConflicts: false
            ) else {
            return .unbound
        }
        return normalizedDefault
    }

    static func reservedSystemWideHotkeyShortcuts(
        excluding currentAction: Action,
        alsoExcluding ignoredActions: Set<Action> = []
    ) -> [StoredShortcut] {
        var reserved: [StoredShortcut] = []

        for action in Action.allCases
        where action != currentAction && !ignoredActions.contains(action) {
            let shortcut = conflictResolutionShortcut(for: action)
            guard !shortcut.isUnbound else { continue }
            if shortcut.hasChord {
                reserved.append(StoredShortcut(first: shortcut.firstStroke))
                continue
            }
            if action.usesNumberedDigitMatching {
                let stroke = shortcut.firstStroke
                reserved.append(
                    contentsOf: (1...9).map { digit in
                        StoredShortcut(
                            key: String(digit),
                            command: stroke.command,
                            shift: stroke.shift,
                            option: stroke.option,
                            control: stroke.control
                        )
                    }
                )
                continue
            }
            reserved.append(shortcut)
        }

        reserved.append(contentsOf: hardcodedSystemWideHotkeyConflicts.filter { currentAction != .showHideAllWindows || $0.key != "`" || !$0.command || $0.option || $0.control })
        return reserved
    }

    static func systemWideHotkeyConflicts(
        with shortcut: StoredShortcut,
        excluding action: Action,
        alsoExcluding ignoredActions: Set<Action> = []
    ) -> Bool {
        guard let registration = shortcut.carbonHotKeyRegistration else {
            return false
        }
        let keyCode = UInt16(registration.keyCode)
        let modifierFlags = shortcut.modifierFlags
        let eventCharacter = KeyboardLayout.character(forKeyCode: keyCode)

        return reservedSystemWideHotkeyShortcuts(
            excluding: action,
            alsoExcluding: ignoredActions
        ).contains { reserved in
            reserved.matches(
                keyCode: keyCode,
                modifierFlags: modifierFlags,
                eventCharacter: eventCharacter
            )
        }
    }

    static func systemWideConflictShortcut(for action: Action) -> StoredShortcut {
        conflictResolutionShortcut(for: action)
    }

    static let hardcodedSystemWideHotkeyConflicts: [StoredShortcut] = [
        StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true),
        StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true),
        StoredShortcut(key: "`", command: true, shift: false, option: false, control: false),
        StoredShortcut(key: "`", command: true, shift: true, option: false, control: false),
    ]
}
