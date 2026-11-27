import Foundation

/// A keystroke macOS claims by default before cmux sees it.
///
/// The list covers shortcuts enabled out of the box in System Settings >
/// Keyboard > Keyboard Shortcuts plus the system screenshot and window
/// switcher keys. It does not read the user's own System Settings changes.
public enum MacOSSystemShortcut: String, CaseIterable, Sendable {
    case spotlight
    case finderSearch
    case previousInputSource
    case nextInputSource
    case appSwitcher
    case appSwitcherReverse
    case nextWindow
    case previousWindow
    case missionControl
    case applicationWindows
    case spaceLeft
    case spaceRight
    case screenshotScreen
    case screenshotSelection
    case screenshotToolbar
    case screenshotScreenToClipboard
    case screenshotSelectionToClipboard
    case toggleDockHiding
    case lockScreen
    case logOut
    case characterViewer
    case lookUp
    case helpMenuSearch
    case focusMenuBar
    case focusDock
    case voiceOver
    case accessibilityShortcuts

    /// The keystroke macOS reserves.
    public var stroke: ShortcutStroke {
        switch self {
        case .spotlight: return ShortcutStroke(key: "space", command: true)
        case .finderSearch: return ShortcutStroke(key: "space", command: true, option: true)
        case .previousInputSource: return ShortcutStroke(key: "space", control: true)
        case .nextInputSource: return ShortcutStroke(key: "space", option: true, control: true)
        case .appSwitcher: return ShortcutStroke(key: "\t", command: true)
        case .appSwitcherReverse: return ShortcutStroke(key: "\t", command: true, shift: true)
        case .nextWindow: return ShortcutStroke(key: "`", command: true)
        case .previousWindow: return ShortcutStroke(key: "`", command: true, shift: true)
        case .missionControl: return ShortcutStroke(key: "↑", control: true)
        case .applicationWindows: return ShortcutStroke(key: "↓", control: true)
        case .spaceLeft: return ShortcutStroke(key: "←", control: true)
        case .spaceRight: return ShortcutStroke(key: "→", control: true)
        case .screenshotScreen: return ShortcutStroke(key: "3", command: true, shift: true)
        case .screenshotSelection: return ShortcutStroke(key: "4", command: true, shift: true)
        case .screenshotToolbar: return ShortcutStroke(key: "5", command: true, shift: true)
        case .screenshotScreenToClipboard:
            return ShortcutStroke(key: "3", command: true, shift: true, control: true)
        case .screenshotSelectionToClipboard:
            return ShortcutStroke(key: "4", command: true, shift: true, control: true)
        case .toggleDockHiding: return ShortcutStroke(key: "d", command: true, option: true)
        case .lockScreen: return ShortcutStroke(key: "q", command: true, control: true)
        case .logOut: return ShortcutStroke(key: "q", command: true, shift: true)
        case .characterViewer: return ShortcutStroke(key: "space", command: true, control: true)
        case .lookUp: return ShortcutStroke(key: "d", command: true, control: true)
        case .helpMenuSearch: return ShortcutStroke(key: "/", command: true, shift: true)
        case .focusMenuBar: return ShortcutStroke(key: "f2", control: true)
        case .focusDock: return ShortcutStroke(key: "f3", control: true)
        case .voiceOver: return ShortcutStroke(key: "f5", command: true)
        case .accessibilityShortcuts: return ShortcutStroke(key: "f5", command: true, option: true)
        }
    }

    /// The macOS shortcuts a binding would collide with.
    ///
    /// Both strokes of a chord are checked, since macOS intercepts either one.
    /// For a numbered action (`usesNumberedDigitMatching`), the binding stands
    /// for its whole `1…9` family, so `cmd+shift+1` collides with the
    /// `cmd+shift+3` screenshot.
    ///
    /// - Parameters:
    ///   - shortcut: The binding to check.
    ///   - action: The action that owns the binding.
    /// - Returns: The colliding macOS shortcuts in declaration order.
    public static func conflicts(
        with shortcut: StoredShortcut,
        for action: ShortcutAction
    ) -> [MacOSSystemShortcut] {
        guard !shortcut.isUnbound else { return [] }
        let strokes = [shortcut.first] + (shortcut.second.map { [$0] } ?? [])
        let numberedStroke = shortcut.second ?? shortcut.first
        let candidates = strokes.flatMap { stroke -> [ShortcutStroke] in
            guard action.usesNumberedDigitMatching, stroke == numberedStroke else {
                return [stroke]
            }
            return (1...9).map { digit in
                ShortcutStroke(
                    key: String(digit),
                    command: stroke.command,
                    shift: stroke.shift,
                    option: stroke.option,
                    control: stroke.control
                )
            }
        }
        return allCases.filter { reserved in
            candidates.contains { $0.matchesIgnoringKeyCode(reserved.stroke) }
        }
    }
}

private extension ShortcutStroke {
    func matchesIgnoringKeyCode(_ other: ShortcutStroke) -> Bool {
        canonicalized().key == other.canonicalized().key
            && command == other.command
            && shift == other.shift
            && option == other.option
            && control == other.control
    }
}
