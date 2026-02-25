import AppKit
import SwiftUI

/// Stores customizable keyboard shortcuts (definitions + persistence).
enum KeyboardShortcutSettings {
    enum Action: String, CaseIterable, Identifiable {
        // Titlebar / primary UI
        case toggleSidebar
        case newTab
        case newWindow
        case closeWindow
        case showNotifications
        case jumpToUnread
        case triggerFlash

        // Navigation
        case nextSurface
        case prevSurface
        case nextSidebarTab
        case prevSidebarTab
        case renameTab
        case renameWorkspace
        case closeWorkspace
        case newSurface

        // Panes / splits
        case focusLeft
        case focusRight
        case focusUp
        case focusDown
        case splitRight
        case splitDown
        case splitBrowserRight
        case splitBrowserDown

        // Panels
        case openBrowser
        case toggleBrowserDeveloperTools
        case showBrowserJavaScriptConsole

        var id: String { rawValue }

        var label: String {
            switch self {
            case .toggleSidebar: return "Toggle Sidebar"
            case .newTab: return "New Workspace"
            case .newWindow: return "New Window"
            case .closeWindow: return "Close Window"
            case .showNotifications: return "Show Notifications"
            case .jumpToUnread: return "Jump to Latest Unread"
            case .triggerFlash: return "Flash Focused Panel"
            case .nextSurface: return "Next Surface"
            case .prevSurface: return "Previous Surface"
            case .nextSidebarTab: return "Next Workspace"
            case .prevSidebarTab: return "Previous Workspace"
            case .renameTab: return "Rename Tab"
            case .renameWorkspace: return "Rename Workspace"
            case .closeWorkspace: return "Close Workspace"
            case .newSurface: return "New Surface"
            case .focusLeft: return "Focus Pane Left"
            case .focusRight: return "Focus Pane Right"
            case .focusUp: return "Focus Pane Up"
            case .focusDown: return "Focus Pane Down"
            case .splitRight: return "Split Right"
            case .splitDown: return "Split Down"
            case .splitBrowserRight: return "Split Browser Right"
            case .splitBrowserDown: return "Split Browser Down"
            case .openBrowser: return "Open Browser"
            case .toggleBrowserDeveloperTools: return "Toggle Browser Developer Tools"
            case .showBrowserJavaScriptConsole: return "Show Browser JavaScript Console"
            }
        }

        var defaultsKey: String {
            switch self {
            case .toggleSidebar: return "shortcut.toggleSidebar"
            case .newTab: return "shortcut.newTab"
            case .newWindow: return "shortcut.newWindow"
            case .closeWindow: return "shortcut.closeWindow"
            case .showNotifications: return "shortcut.showNotifications"
            case .jumpToUnread: return "shortcut.jumpToUnread"
            case .triggerFlash: return "shortcut.triggerFlash"
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
            case .splitBrowserRight: return "shortcut.splitBrowserRight"
            case .splitBrowserDown: return "shortcut.splitBrowserDown"
            case .nextSurface: return "shortcut.nextSurface"
            case .prevSurface: return "shortcut.prevSurface"
            case .newSurface: return "shortcut.newSurface"
            case .openBrowser: return "shortcut.openBrowser"
            case .toggleBrowserDeveloperTools: return "shortcut.toggleBrowserDeveloperTools"
            case .showBrowserJavaScriptConsole: return "shortcut.showBrowserJavaScriptConsole"
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
                return StoredShortcut(key: "r", command: true, shift: false, option: false, control: true)
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
            case .splitBrowserRight:
                return StoredShortcut(key: "d", command: true, shift: false, option: true, control: false)
            case .splitBrowserDown:
                return StoredShortcut(key: "d", command: true, shift: true, option: true, control: false)
            case .nextSurface:
                return StoredShortcut(key: "]", command: true, shift: true, option: false, control: false)
            case .prevSurface:
                return StoredShortcut(key: "[", command: true, shift: true, option: false, control: false)
            case .newSurface:
                return StoredShortcut(key: "t", command: true, shift: false, option: false, control: false)
            case .openBrowser:
                return StoredShortcut(key: "l", command: true, shift: true, option: false, control: false)
            case .toggleBrowserDeveloperTools:
                // Safari default: Show Web Inspector.
                return StoredShortcut(key: "i", command: true, shift: false, option: true, control: false)
            case .showBrowserJavaScriptConsole:
                // Safari default: Show JavaScript Console.
                return StoredShortcut(key: "c", command: true, shift: false, option: true, control: false)
            }
        }

        func tooltip(_ base: String) -> String {
            "\(base) (\(KeyboardShortcutSettings.shortcut(for: self).displayString))"
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
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
    }

    static func resetShortcut(for action: Action) {
        UserDefaults.standard.removeObject(forKey: action.defaultsKey)
    }

    static func resetAll() {
        for action in Action.allCases {
            resetShortcut(for: action)
        }
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
    static func splitBrowserRightShortcut() -> StoredShortcut { shortcut(for: .splitBrowserRight) }
    static func splitBrowserDownShortcut() -> StoredShortcut { shortcut(for: .splitBrowserDown) }

    static func nextSurfaceShortcut() -> StoredShortcut { shortcut(for: .nextSurface) }
    static func prevSurfaceShortcut() -> StoredShortcut { shortcut(for: .prevSurface) }
    static func newSurfaceShortcut() -> StoredShortcut { shortcut(for: .newSurface) }

    static func openBrowserShortcut() -> StoredShortcut { shortcut(for: .openBrowser) }
    static func toggleBrowserDeveloperToolsShortcut() -> StoredShortcut { shortcut(for: .toggleBrowserDeveloperTools) }
    static func showBrowserJavaScriptConsoleShortcut() -> StoredShortcut { shortcut(for: .showBrowserJavaScriptConsole) }
}

/// A keyboard shortcut that can be stored in UserDefaults
struct StoredShortcut: Codable, Equatable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    var displayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        let keyText: String
        switch key {
        case "\t":
            keyText = "TAB"
        default:
            keyText = key.uppercased()
        }
        parts.append(keyText)
        return parts.joined()
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
        default:
            let lowered = key.lowercased()
            guard lowered.count == 1 else { return nil }
            return lowered
        }
    }

    static func from(event: NSEvent) -> StoredShortcut? {
        guard let key = storedKey(from: event) else { return nil }

        // Some keys include extra flags depending on the responder chain.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])

        let shortcut = StoredShortcut(
            key: key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )

        // Avoid recording plain typing; require at least one modifier.
        if !shortcut.command && !shortcut.shift && !shortcut.option && !shortcut.control {
            return nil
        }
        return shortcut
    }

    private static func storedKey(from event: NSEvent) -> String? {
        // Prefer keyCode mapping so shifted symbol keys (e.g. "}") record as "]".
        switch event.keyCode {
        case 123: return "←" // left arrow
        case 124: return "→" // right arrow
        case 125: return "↓" // down arrow
        case 126: return "↑" // up arrow
        case 48: return "\t" // tab
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

        // Allow letters/numbers; everything else should be handled by keyCode mapping above.
        if char.isLetter || char.isNumber {
            return String(char)
        }
        return nil
    }
}

/// View for recording a keyboard shortcut
struct KeyboardShortcutRecorder: View {
    let label: String
    @Binding var shortcut: StoredShortcut
    @State private var isRecording = false

    var body: some View {
        HStack {
            Text(label)

            Spacer()

            ShortcutRecorderButton(shortcut: $shortcut, isRecording: $isRecording)
                .frame(width: 120)
        }
    }
}

private struct ShortcutRecorderButton: NSViewRepresentable {
    @Binding var shortcut: StoredShortcut
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> ShortcutRecorderNSButton {
        let button = ShortcutRecorderNSButton()
        button.shortcut = shortcut
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
        nsView.updateTitle()
    }
}

private class ShortcutRecorderNSButton: NSButton {
    var shortcut: StoredShortcut = KeyboardShortcutSettings.showNotificationsDefault
    var onShortcutRecorded: ((StoredShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var isRecording = false
    private var eventMonitor: Any?

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
            title = "Press shortcut…"
        } else {
            title = shortcut.displayString
        }
    }

    @objc private func buttonClicked() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        onRecordingChanged?(true)
        updateTitle()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if event.keyCode == 53 { // Escape
                self.stopRecording()
                return nil
            }

            if let newShortcut = StoredShortcut.from(event: event) {
                self.shortcut = newShortcut
                self.onShortcutRecorded?(newShortcut)
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
