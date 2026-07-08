import Foundation

/// System-wide shortcut conflict helpers extracted from `KeyboardShortcutSettings.swift`, which sits at its file-length budget.
extension KeyboardShortcutSettings {
    static func reservedSystemWideHotkeyShortcuts(excluding currentAction: Action) -> [StoredShortcut] {
        var reserved: [StoredShortcut] = []

        for action in Action.allCases where action != currentAction {
            let shortcut = systemWideConflictShortcut(for: action)
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

    static func systemWideConflictShortcut(for action: Action) -> StoredShortcut {
        switch action {
        case .showHideAllWindows:
            return SystemWideHotkeySettings.shortcut()
        default:
            return KeyboardShortcutSettings.shortcut(for: action)
        }
    }

    static let hardcodedSystemWideHotkeyConflicts: [StoredShortcut] = [
        StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true),
        StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true),
        StoredShortcut(key: "`", command: true, shift: false, option: false, control: false),
        StoredShortcut(key: "`", command: true, shift: true, option: false, control: false),
        // Cmd+. is AppKit's standard cancel keystroke for modal alerts and
        // open/save panels. Refuse to register it as the global hotkey so the
        // first instinctive "cancel" press never hides the whole app.
        StoredShortcut(key: ".", command: true, shift: false, option: false, control: false),
    ]
}
