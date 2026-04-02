import AppKit
import SwiftUI

/// Stores customizable keyboard shortcuts (definitions + persistence).
enum KeyboardShortcutSettings {
    static let didChangeNotification = Notification.Name("cmux.keyboardShortcutSettingsDidChange")
    static let actionUserInfoKey = "action"

    enum Action: String, CaseIterable, Identifiable {
        // Titlebar / primary UI
        case toggleSidebar
        case newTab
        case newWindow
        case closeWindow
        case openFolder
        case sendFeedback
        case showNotifications
        case jumpToUnread
        case triggerFlash

        // Navigation
        case nextSurface
        case prevSurface
        case selectSurfaceByNumber
        case nextSidebarTab
        case prevSidebarTab
        case selectWorkspaceByNumber
        case renameTab
        case renameWorkspace
        case closeWorkspace
        case newSurface
        case toggleTerminalCopyMode

        // Panes / splits
        case focusLeft
        case focusRight
        case focusUp
        case focusDown
        case splitRight
        case splitDown
        case toggleSplitZoom
        case splitBrowserRight
        case splitBrowserDown

        // Panels
        case openBrowser
        case toggleBrowserDeveloperTools
        case showBrowserJavaScriptConsole
        case toggleReactGrab

        var id: String { rawValue }

        var label: String {
            switch self {
            case .toggleSidebar: return String(localized: "shortcut.toggleSidebar.label", defaultValue: "Toggle Sidebar")
            case .newTab: return String(localized: "shortcut.newWorkspace.label", defaultValue: "New Workspace")
            case .newWindow: return String(localized: "shortcut.newWindow.label", defaultValue: "New Window")
            case .closeWindow: return String(localized: "shortcut.closeWindow.label", defaultValue: "Close Window")
            case .openFolder: return String(localized: "shortcut.openFolder.label", defaultValue: "Open Folder")
            case .sendFeedback: return String(localized: "sidebar.help.sendFeedback", defaultValue: "Send Feedback")
            case .showNotifications: return String(localized: "shortcut.showNotifications.label", defaultValue: "Show Notifications")
            case .jumpToUnread: return String(localized: "shortcut.jumpToUnread.label", defaultValue: "Jump to Latest Unread")
            case .triggerFlash: return String(localized: "shortcut.flashFocusedPanel.label", defaultValue: "Flash Focused Panel")
            case .nextSurface: return String(localized: "shortcut.nextSurface.label", defaultValue: "Next Surface")
            case .prevSurface: return String(localized: "shortcut.previousSurface.label", defaultValue: "Previous Surface")
            case .selectSurfaceByNumber: return String(localized: "shortcut.selectSurfaceByNumber.label", defaultValue: "Select Surface 1…9")
            case .nextSidebarTab: return String(localized: "shortcut.nextWorkspace.label", defaultValue: "Next Workspace")
            case .prevSidebarTab: return String(localized: "shortcut.previousWorkspace.label", defaultValue: "Previous Workspace")
            case .selectWorkspaceByNumber: return String(localized: "shortcut.selectWorkspaceByNumber.label", defaultValue: "Select Workspace 1…9")
            case .renameTab: return String(localized: "shortcut.renameTab.label", defaultValue: "Rename Tab")
            case .renameWorkspace: return String(localized: "shortcut.renameWorkspace.label", defaultValue: "Rename Workspace")
            case .closeWorkspace: return String(localized: "shortcut.closeWorkspace.label", defaultValue: "Close Workspace")
            case .newSurface: return String(localized: "shortcut.newSurface.label", defaultValue: "New Surface")
            case .toggleTerminalCopyMode: return String(localized: "shortcut.toggleTerminalCopyMode.label", defaultValue: "Toggle Terminal Copy Mode")
            case .focusLeft: return String(localized: "shortcut.focusPaneLeft.label", defaultValue: "Focus Pane Left")
            case .focusRight: return String(localized: "shortcut.focusPaneRight.label", defaultValue: "Focus Pane Right")
            case .focusUp: return String(localized: "shortcut.focusPaneUp.label", defaultValue: "Focus Pane Up")
            case .focusDown: return String(localized: "shortcut.focusPaneDown.label", defaultValue: "Focus Pane Down")
            case .splitRight: return String(localized: "shortcut.splitRight.label", defaultValue: "Split Right")
            case .splitDown: return String(localized: "shortcut.splitDown.label", defaultValue: "Split Down")
            case .toggleSplitZoom: return String(localized: "shortcut.togglePaneZoom.label", defaultValue: "Toggle Pane Zoom")
            case .splitBrowserRight: return String(localized: "shortcut.splitBrowserRight.label", defaultValue: "Split Browser Right")
            case .splitBrowserDown: return String(localized: "shortcut.splitBrowserDown.label", defaultValue: "Split Browser Down")
            case .openBrowser: return String(localized: "shortcut.openBrowser.label", defaultValue: "Open Browser")
            case .toggleBrowserDeveloperTools: return String(localized: "shortcut.toggleBrowserDevTools.label", defaultValue: "Toggle Browser Developer Tools")
            case .showBrowserJavaScriptConsole: return String(localized: "shortcut.showBrowserJSConsole.label", defaultValue: "Show Browser JavaScript Console")
            case .toggleReactGrab: return String(localized: "shortcut.toggleReactGrab.label", defaultValue: "Toggle React Grab")
            }
        }

        var defaultsKey: String {
            switch self {
            case .toggleSidebar: return "shortcut.toggleSidebar"
            case .newTab: return "shortcut.newTab"
            case .newWindow: return "shortcut.newWindow"
            case .closeWindow: return "shortcut.closeWindow"
            case .openFolder: return "shortcut.openFolder"
            case .sendFeedback: return "shortcut.sendFeedback"
            case .showNotifications: return "shortcut.showNotifications"
            case .jumpToUnread: return "shortcut.jumpToUnread"
            case .triggerFlash: return "shortcut.triggerFlash"
            case .selectWorkspaceByNumber: return "shortcut.selectWorkspaceByNumber"
            case .nextSidebarTab: return "shortcut.nextSidebarTab"
            case .prevSidebarTab: return "shortcut.prevSidebarTab"
            case .renameTab: return "shortcut.renameTab"
            case .renameWorkspace: return "shortcut.renameWorkspace"
            case .closeWorkspace: return "shortcut.closeWorkspace"
            case .focusLeft: return "shortcut.focusLeft"
            case .focusRight: return "shortcut.focusRight"
            case .focusUp: return "shortcut.focusUp"
            case .focusDown: return "shortcut.focusDown"
            case .splitRight: return "shortcut.splitRight"
            case .splitDown: return "shortcut.splitDown"
            case .toggleSplitZoom: return "shortcut.toggleSplitZoom"
            case .splitBrowserRight: return "shortcut.splitBrowserRight"
            case .splitBrowserDown: return "shortcut.splitBrowserDown"
            case .nextSurface: return "shortcut.nextSurface"
            case .prevSurface: return "shortcut.prevSurface"
            case .selectSurfaceByNumber: return "shortcut.selectSurfaceByNumber"
            case .newSurface: return "shortcut.newSurface"
            case .toggleTerminalCopyMode: return "shortcut.toggleTerminalCopyMode"
            case .openBrowser: return "shortcut.openBrowser"
            case .toggleBrowserDeveloperTools: return "shortcut.toggleBrowserDeveloperTools"
            case .showBrowserJavaScriptConsole: return "shortcut.showBrowserJavaScriptConsole"
            case .toggleReactGrab: return "shortcut.toggleReactGrab"
            }
        }

        var defaultShortcut: StoredShortcut {
            switch self {
            case .toggleSidebar:
                return StoredShortcut(key: "b", command: true, shift: false, option: false, control: false)
            case .newTab:
                return StoredShortcut(key: "n", command: true, shift: false, option: false, control: false)
            case .newWindow:
                return StoredShortcut(key: "n", command: true, shift: true, option: false, control: false)
            case .closeWindow:
                return StoredShortcut(key: "w", command: true, shift: false, option: false, control: true)
            case .openFolder:
                return StoredShortcut(key: "o", command: true, shift: false, option: false, control: false)
            case .sendFeedback:
                return StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
            case .showNotifications:
                return StoredShortcut(key: "i", command: true, shift: false, option: false, control: false)
            case .jumpToUnread:
                return StoredShortcut(key: "u", command: true, shift: true, option: false, control: false)
            case .triggerFlash:
                return StoredShortcut(key: "h", command: true, shift: true, option: false, control: false)
            case .nextSidebarTab:
                return StoredShortcut(key: "]", command: true, shift: false, option: false, control: true)
            case .prevSidebarTab:
                return StoredShortcut(key: "[", command: true, shift: false, option: false, control: true)
            case .renameTab:
                return StoredShortcut(key: "r", command: true, shift: false, option: false, control: false)
            case .renameWorkspace:
                return StoredShortcut(key: "r", command: true, shift: true, option: false, control: false)
            case .closeWorkspace:
                return StoredShortcut(key: "w", command: true, shift: true, option: false, control: false)
            case .focusLeft:
                return StoredShortcut(key: "←", command: true, shift: false, option: true, control: false)
            case .focusRight:
                return StoredShortcut(key: "→", command: true, shift: false, option: true, control: false)
            case .focusUp:
                return StoredShortcut(key: "↑", command: true, shift: false, option: true, control: false)
            case .focusDown:
                return StoredShortcut(key: "↓", command: true, shift: false, option: true, control: false)
            case .splitRight:
                return StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
            case .splitDown:
                return StoredShortcut(key: "d", command: true, shift: true, option: false, control: false)
            case .toggleSplitZoom:
                return StoredShortcut(key: "\r", command: true, shift: true, option: false, control: false)
            case .splitBrowserRight:
                return StoredShortcut(key: "d", command: true, shift: false, option: true, control: false)
            case .splitBrowserDown:
                return StoredShortcut(key: "d", command: true, shift: true, option: true, control: false)
            case .nextSurface:
                return StoredShortcut(key: "]", command: true, shift: true, option: false, control: false)
            case .prevSurface:
                return StoredShortcut(key: "[", command: true, shift: true, option: false, control: false)
            case .selectSurfaceByNumber:
                return StoredShortcut(key: "1", command: false, shift: false, option: false, control: true)
            case .newSurface:
                return StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
            case .toggleTerminalCopyMode:
                return StoredShortcut(key: "m", command: true, shift: true, option: false, control: false)
            case .selectWorkspaceByNumber:
                return StoredShortcut(key: "1", command: true, shift: false, option: false, control: false)
            case .openBrowser:
                return StoredShortcut(key: "l", command: true, shift: true, option: false, control: false)
            case .toggleBrowserDeveloperTools:
                // Safari default: Show Web Inspector.
                return StoredShortcut(key: "i", command: true, shift: false, option: true, control: false)
            case .showBrowserJavaScriptConsole:
                // Safari default: Show JavaScript Console.
                return StoredShortcut(key: "c", command: true, shift: false, option: true, control: false)
            case .toggleReactGrab:
                return StoredShortcut(key: "g", command: true, shift: true, option: false, control: false)
            }
        }

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

        func displayedShortcutString(for shortcut: StoredShortcut) -> String {
            if usesNumberedDigitMatching {
                return shortcut.numberedDisplayString
            }
            return shortcut.displayString
        }

        func normalizedRecordedShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
            guard usesNumberedDigitMatching else { return shortcut }
            let digitSource = shortcut.secondStroke ?? shortcut.firstStroke
            guard let digit = Int(digitSource.key), (1...9).contains(digit) else {
                return nil
            }
            var normalized = shortcut
            if shortcut.hasChord {
                normalized.chordKey = "1"
            } else {
                normalized.key = "1"
            }
            return normalized
        }
    }

    static func shortcut(for action: Action) -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return action.defaultShortcut
        }
        return shortcut
    }

    static func setShortcut(_ shortcut: StoredShortcut, for action: Action) {
        let storedShortcut: StoredShortcut
        if let normalizedShortcut = action.normalizedRecordedShortcut(shortcut) {
            storedShortcut = normalizedShortcut
        } else if action.usesNumberedDigitMatching {
            return
        } else {
            storedShortcut = shortcut
        }

        if let data = try? JSONEncoder().encode(storedShortcut) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
        postDidChangeNotification(action: action)
    }

    static func resetShortcut(for action: Action) {
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        postDidChangeNotification(action: action)
    }

    static func resetAll() {
        for action in Action.allCases {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
        postDidChangeNotification()
    }

    private static func postDidChangeNotification(
        action: Action? = nil,
        center: NotificationCenter = .default
    ) {
        var userInfo: [AnyHashable: Any] = [:]
        if let action {
            userInfo[actionUserInfoKey] = action.rawValue
        }
        center.post(
            name: didChangeNotification,
            object: nil,
            userInfo: userInfo.isEmpty ? nil : userInfo
        )
    }

    // MARK: - Backwards-Compatible API (call-sites can migrate gradually)

    // Keys (used by debug socket command + UI tests)
    static let focusLeftKey = Action.focusLeft.defaultsKey
    static let focusRightKey = Action.focusRight.defaultsKey
    static let focusUpKey = Action.focusUp.defaultsKey
    static let focusDownKey = Action.focusDown.defaultsKey

    // Defaults (used by settings reset + recorder button initial title)
    static let showNotificationsDefault = Action.showNotifications.defaultShortcut
    static let jumpToUnreadDefault = Action.jumpToUnread.defaultShortcut

    static func showNotificationsShortcut() -> StoredShortcut { shortcut(for: .showNotifications) }
    static func setShowNotificationsShortcut(_ shortcut: StoredShortcut) { setShortcut(shortcut, for: .showNotifications) }

    static func jumpToUnreadShortcut() -> StoredShortcut { shortcut(for: .jumpToUnread) }
    static func setJumpToUnreadShortcut(_ shortcut: StoredShortcut) { setShortcut(shortcut, for: .jumpToUnread) }

    static func nextSidebarTabShortcut() -> StoredShortcut { shortcut(for: .nextSidebarTab) }
    static func prevSidebarTabShortcut() -> StoredShortcut { shortcut(for: .prevSidebarTab) }
    static func renameWorkspaceShortcut() -> StoredShortcut { shortcut(for: .renameWorkspace) }
    static func closeWorkspaceShortcut() -> StoredShortcut { shortcut(for: .closeWorkspace) }

    static func focusLeftShortcut() -> StoredShortcut { shortcut(for: .focusLeft) }
    static func focusRightShortcut() -> StoredShortcut { shortcut(for: .focusRight) }
    static func focusUpShortcut() -> StoredShortcut { shortcut(for: .focusUp) }
    static func focusDownShortcut() -> StoredShortcut { shortcut(for: .focusDown) }

    static func splitRightShortcut() -> StoredShortcut { shortcut(for: .splitRight) }
    static func splitDownShortcut() -> StoredShortcut { shortcut(for: .splitDown) }
    static func toggleSplitZoomShortcut() -> StoredShortcut { shortcut(for: .toggleSplitZoom) }
    static func splitBrowserRightShortcut() -> StoredShortcut { shortcut(for: .splitBrowserRight) }
    static func splitBrowserDownShortcut() -> StoredShortcut { shortcut(for: .splitBrowserDown) }

    static func nextSurfaceShortcut() -> StoredShortcut { shortcut(for: .nextSurface) }
    static func prevSurfaceShortcut() -> StoredShortcut { shortcut(for: .prevSurface) }
    static func selectSurfaceByNumberShortcut() -> StoredShortcut { shortcut(for: .selectSurfaceByNumber) }
    static func newSurfaceShortcut() -> StoredShortcut { shortcut(for: .newSurface) }
    static func selectWorkspaceByNumberShortcut() -> StoredShortcut { shortcut(for: .selectWorkspaceByNumber) }

    static func openBrowserShortcut() -> StoredShortcut { shortcut(for: .openBrowser) }
    static func toggleBrowserDeveloperToolsShortcut() -> StoredShortcut { shortcut(for: .toggleBrowserDeveloperTools) }
    static func showBrowserJavaScriptConsoleShortcut() -> StoredShortcut { shortcut(for: .showBrowserJavaScriptConsole) }
}

struct ShortcutStroke: Equatable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    var displayString: String {
        modifierDisplayString + keyDisplayString
    }

    var modifierDisplayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        return parts.joined()
    }

    var keyDisplayString: String {
        switch key {
        case "\t":
            return "TAB"
        case "\r":
            return "↩"
        default:
            return key.uppercased()
        }
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "←":
            return .leftArrow
        case "→":
            return .rightArrow
        case "↑":
            return .upArrow
        case "↓":
            return .downArrow
        case "\t":
            return .tab
        case "\r":
            return KeyEquivalent(Character("\r"))
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1, let character = lowered.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command {
            modifiers.insert(.command)
        }
        if shift {
            modifiers.insert(.shift)
        }
        if option {
            modifiers.insert(.option)
        }
        if control {
            modifiers.insert(.control)
        }
        return modifiers
    }

    var menuItemKeyEquivalent: String? {
        switch key {
        case "←":
            guard let scalar = UnicodeScalar(NSLeftArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "→":
            guard let scalar = UnicodeScalar(NSRightArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↑":
            guard let scalar = UnicodeScalar(NSUpArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "↓":
            guard let scalar = UnicodeScalar(NSDownArrowFunctionKey) else { return nil }
            return String(Character(scalar))
        case "\t":
            return "\t"
        case "\r":
            return "\r"
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }

    static func isEscapeCancelEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            return true
        }

        let escapeScalar = UnicodeScalar(0x1B)!
        if event.characters?.unicodeScalars.contains(escapeScalar) == true {
            return true
        }
        if event.charactersIgnoringModifiers?.unicodeScalars.contains(escapeScalar) == true {
            return true
        }
        return false
    }

    static func from(event: NSEvent, requireModifier: Bool = true) -> ShortcutStroke? {
        guard !isEscapeCancelEvent(event),
              let key = storedKey(from: event) else { return nil }

        // Some keys include extra flags depending on the responder chain.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])

        let stroke = ShortcutStroke(
            key: key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )

        if requireModifier,
           !stroke.command && !stroke.shift && !stroke.option && !stroke.control {
            return nil
        }
        return stroke
    }

    private static func storedKey(from event: NSEvent) -> String? {
        // Prefer keyCode mapping so shifted symbol keys (e.g. "}") record as "]".
        switch event.keyCode {
        case 123: return "←" // left arrow
        case 124: return "→" // right arrow
        case 125: return "↓" // down arrow
        case 126: return "↑" // up arrow
        case 48: return "\t" // tab
        case 36, 76: return "\r" // return, keypad enter
        case 33: return "["  // kVK_ANSI_LeftBracket
        case 30: return "]"  // kVK_ANSI_RightBracket
        case 27: return "-"  // kVK_ANSI_Minus
        case 24: return "="  // kVK_ANSI_Equal
        case 43: return ","  // kVK_ANSI_Comma
        case 47: return "."  // kVK_ANSI_Period
        case 44: return "/"  // kVK_ANSI_Slash
        case 41: return ";"  // kVK_ANSI_Semicolon
        case 39: return "'"  // kVK_ANSI_Quote
        case 50: return "`"  // kVK_ANSI_Grave
        case 42: return "\\" // kVK_ANSI_Backslash
        default:
            break
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let char = chars.first else {
            return nil
        }

        if char.isLetter || char.isNumber {
            return String(char)
        }
        return nil
    }
}

/// A keyboard shortcut that can be stored in UserDefaults
struct StoredShortcut: Codable, Equatable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var chordKey: String?
    var chordCommand: Bool
    var chordShift: Bool
    var chordOption: Bool
    var chordControl: Bool

    init(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool,
        chordKey: String? = nil,
        chordCommand: Bool = false,
        chordShift: Bool = false,
        chordOption: Bool = false,
        chordControl: Bool = false
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.chordKey = chordKey?.isEmpty == true ? nil : chordKey
        self.chordCommand = chordCommand
        self.chordShift = chordShift
        self.chordOption = chordOption
        self.chordControl = chordControl
    }

    init(first: ShortcutStroke, second: ShortcutStroke? = nil) {
        self.init(
            key: first.key,
            command: first.command,
            shift: first.shift,
            option: first.option,
            control: first.control,
            chordKey: second?.key,
            chordCommand: second?.command ?? false,
            chordShift: second?.shift ?? false,
            chordOption: second?.option ?? false,
            chordControl: second?.control ?? false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case command
        case shift
        case option
        case control
        case chordKey
        case chordCommand
        case chordShift
        case chordOption
        case chordControl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            command: try container.decode(Bool.self, forKey: .command),
            shift: try container.decode(Bool.self, forKey: .shift),
            option: try container.decode(Bool.self, forKey: .option),
            control: try container.decode(Bool.self, forKey: .control),
            chordKey: try container.decodeIfPresent(String.self, forKey: .chordKey),
            chordCommand: try container.decodeIfPresent(Bool.self, forKey: .chordCommand) ?? false,
            chordShift: try container.decodeIfPresent(Bool.self, forKey: .chordShift) ?? false,
            chordOption: try container.decodeIfPresent(Bool.self, forKey: .chordOption) ?? false,
            chordControl: try container.decodeIfPresent(Bool.self, forKey: .chordControl) ?? false
        )
    }

    var firstStroke: ShortcutStroke {
        ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    var secondStroke: ShortcutStroke? {
        guard let chordKey else { return nil }
        return ShortcutStroke(
            key: chordKey,
            command: chordCommand,
            shift: chordShift,
            option: chordOption,
            control: chordControl
        )
    }

    var hasChord: Bool {
        secondStroke != nil
    }

    var displayString: String {
        if let secondStroke {
            return "\(firstStroke.displayString) \(secondStroke.displayString)"
        }
        return firstStroke.displayString
    }

    var numberedDisplayString: String {
        if hasChord {
            return numberedDigitHintPrefix + "1…9"
        }
        return firstStroke.modifierDisplayString + "1…9"
    }

    var numberedDigitHintPrefix: String {
        if let secondStroke {
            return "\(firstStroke.displayString) \(secondStroke.modifierDisplayString)"
        }
        return firstStroke.modifierDisplayString
    }

    var modifierDisplayString: String {
        firstStroke.modifierDisplayString
    }

    var keyDisplayString: String {
        firstStroke.keyDisplayString
    }

    var modifierFlags: NSEvent.ModifierFlags {
        firstStroke.modifierFlags
    }

    var keyEquivalent: KeyEquivalent? {
        guard !hasChord else { return nil }
        return firstStroke.keyEquivalent
    }

    var eventModifiers: EventModifiers {
        firstStroke.eventModifiers
    }

    var menuItemKeyEquivalent: String? {
        guard !hasChord else { return nil }
        return firstStroke.menuItemKeyEquivalent
    }

    static func from(event: NSEvent) -> StoredShortcut? {
        guard let stroke = ShortcutStroke.from(event: event) else { return nil }
        return StoredShortcut(first: stroke)
    }
}

/// View for recording a keyboard shortcut
struct KeyboardShortcutRecorder: View {
    let label: String
    @Binding var shortcut: StoredShortcut
    var displayString: (StoredShortcut) -> String = { $0.displayString }
    var transformRecordedShortcut: (StoredShortcut) -> StoredShortcut? = { $0 }
    @State private var isRecording = false

    var body: some View {
        HStack {
            Text(label)

            Spacer()

            ShortcutRecorderButton(
                shortcut: $shortcut,
                isRecording: $isRecording,
                displayString: displayString,
                transformRecordedShortcut: transformRecordedShortcut
            )
                .frame(width: 160)
        }
    }
}

private struct ShortcutRecorderButton: NSViewRepresentable {
    @Binding var shortcut: StoredShortcut
    @Binding var isRecording: Bool
    let displayString: (StoredShortcut) -> String
    let transformRecordedShortcut: (StoredShortcut) -> StoredShortcut?

    func makeNSView(context: Context) -> ShortcutRecorderNSButton {
        let button = ShortcutRecorderNSButton()
        button.shortcut = shortcut
        button.displayString = displayString
        button.transformRecordedShortcut = transformRecordedShortcut
        button.onShortcutRecorded = { newShortcut in
            shortcut = newShortcut
            isRecording = false
        }
        button.onRecordingChanged = { recording in
            isRecording = recording
        }
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderNSButton, context: Context) {
        nsView.shortcut = shortcut
        nsView.displayString = displayString
        nsView.transformRecordedShortcut = transformRecordedShortcut
        nsView.updateTitle()
    }
}

private class ShortcutRecorderNSButton: NSButton {
    var shortcut: StoredShortcut = KeyboardShortcutSettings.showNotificationsDefault
    var displayString: (StoredShortcut) -> String = { $0.displayString }
    var transformRecordedShortcut: (StoredShortcut) -> StoredShortcut? = { $0 }
    var onShortcutRecorded: ((StoredShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var isRecording = false
    private var eventMonitor: Any?
    private var pendingChordStart: ShortcutStroke?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(buttonClicked)
        updateTitle()
    }

    func updateTitle() {
        if isRecording {
            if let pendingChordStart {
                title = "\(pendingChordStart.displayString) …"
            } else {
                title = String(localized: "shortcut.pressShortcut.prompt", defaultValue: "Press shortcut…")
            }
        } else {
            title = displayString(shortcut)
        }
    }

    @objc private func buttonClicked() {
        if isRecording {
            if let pendingChordStart {
                let storedShortcut = StoredShortcut(first: pendingChordStart)
                guard let transformedShortcut = transformRecordedShortcut(storedShortcut) else {
                    NSSound.beep()
                    return
                }
                shortcut = transformedShortcut
                onShortcutRecorded?(transformedShortcut)
            }
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        pendingChordStart = nil
        onRecordingChanged?(true)
        updateTitle()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if ShortcutStroke.isEscapeCancelEvent(event) {
                self.stopRecording()
                return nil
            }

            if self.pendingChordStart == nil {
                guard let firstStroke = ShortcutStroke.from(event: event, requireModifier: true) else {
                    return nil
                }
                self.pendingChordStart = firstStroke
                self.updateTitle()
                return nil
            }

            guard let pendingChordStart = self.pendingChordStart else {
                return nil
            }

            if let secondStroke = ShortcutStroke.from(event: event, requireModifier: false) {
                let newShortcut = StoredShortcut(first: pendingChordStart, second: secondStroke)
                guard let transformedShortcut = self.transformRecordedShortcut(newShortcut) else {
                    NSSound.beep()
                    return nil
                }
                self.shortcut = transformedShortcut
                self.onShortcutRecorded?(transformedShortcut)
                self.stopRecording()
                return nil
            }

            // Consume unsupported keys while recording to avoid triggering app shortcuts.
            return nil
        }

        // Also stop recording if window loses focus
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResigned),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    private func stopRecording() {
        isRecording = false
        pendingChordStart = nil
        onRecordingChanged?(false)
        updateTitle()

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowResigned() {
        stopRecording()
    }

    deinit {
        stopRecording()
    }
}
