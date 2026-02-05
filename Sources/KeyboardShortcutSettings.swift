import AppKit
import SwiftUI

/// Stores customizable keyboard shortcuts
enum KeyboardShortcutSettings {
    // MARK: - Notification Shortcuts
    static let showNotificationsKey = "shortcut.showNotifications"
    static let jumpToUnreadKey = "shortcut.jumpToUnread"

    /// Default shortcut: Cmd+Shift+I
    static let showNotificationsDefault = StoredShortcut(key: "i", command: true, shift: true, option: false, control: false)
    /// Default shortcut: Cmd+Shift+U
    static let jumpToUnreadDefault = StoredShortcut(key: "u", command: true, shift: true, option: false, control: false)

    // MARK: - Sidebar Tab Navigation Keys
    static let nextSidebarTabKey = "shortcut.nextSidebarTab"
    static let prevSidebarTabKey = "shortcut.prevSidebarTab"

    /// Default shortcut: Cmd+] (next sidebar tab)
    static let nextSidebarTabDefault = StoredShortcut(key: "]", command: true, shift: false, option: false, control: false)
    /// Default shortcut: Cmd+[ (previous sidebar tab)
    static let prevSidebarTabDefault = StoredShortcut(key: "[", command: true, shift: false, option: false, control: false)

    // MARK: - Pane Navigation Keys
    static let focusLeftKey = "shortcut.focusLeft"
    static let focusRightKey = "shortcut.focusRight"
    static let focusUpKey = "shortcut.focusUp"
    static let focusDownKey = "shortcut.focusDown"

    /// Default shortcuts for pane navigation: Cmd+Option+Arrow
    static let focusLeftDefault = StoredShortcut(key: "←", command: true, shift: false, option: true, control: false)
    static let focusRightDefault = StoredShortcut(key: "→", command: true, shift: false, option: true, control: false)
    static let focusUpDefault = StoredShortcut(key: "↑", command: true, shift: false, option: true, control: false)
    static let focusDownDefault = StoredShortcut(key: "↓", command: true, shift: false, option: true, control: false)

    // MARK: - Split Actions Keys
    static let splitRightKey = "shortcut.splitRight"
    static let splitDownKey = "shortcut.splitDown"

    /// Default shortcut: Cmd+D (split right)
    static let splitRightDefault = StoredShortcut(key: "d", command: true, shift: false, option: false, control: false)
    /// Default shortcut: Cmd+Shift+D (split down)
    static let splitDownDefault = StoredShortcut(key: "d", command: true, shift: true, option: false, control: false)

    // MARK: - Bonsplit Tab Navigation Keys
    static let nextBonsplitTabKey = "shortcut.nextBonsplitTab"
    static let prevBonsplitTabKey = "shortcut.prevBonsplitTab"
    static let newBonsplitTabKey = "shortcut.newBonsplitTab"

    /// Default shortcut: Ctrl+Tab (next bonsplit tab)
    static let nextBonsplitTabDefault = StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)
    /// Default shortcut: Ctrl+Shift+Tab (previous bonsplit tab)
    static let prevBonsplitTabDefault = StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)
    /// Default shortcut: Cmd+Shift+T (new bonsplit tab in focused pane)
    static let newBonsplitTabDefault = StoredShortcut(key: "t", command: true, shift: true, option: false, control: false)

    // MARK: - Browser Keys
    static let openBrowserKey = "shortcut.openBrowser"

    /// Default shortcut: Cmd+Shift+B (open browser)
    static let openBrowserDefault = StoredShortcut(key: "b", command: true, shift: true, option: false, control: false)

    static func showNotificationsShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: showNotificationsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return showNotificationsDefault
        }
        return shortcut
    }

    static func setShowNotificationsShortcut(_ shortcut: StoredShortcut) {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: showNotificationsKey)
        }
    }

    static func jumpToUnreadShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: jumpToUnreadKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return jumpToUnreadDefault
        }
        return shortcut
    }

    static func setJumpToUnreadShortcut(_ shortcut: StoredShortcut) {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: jumpToUnreadKey)
        }
    }

    // MARK: - Sidebar Tab Navigation Accessors

    static func nextSidebarTabShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: nextSidebarTabKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return nextSidebarTabDefault
        }
        return shortcut
    }

    static func prevSidebarTabShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: prevSidebarTabKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return prevSidebarTabDefault
        }
        return shortcut
    }

    // MARK: - Pane Navigation Accessors

    static func focusLeftShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: focusLeftKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return focusLeftDefault
        }
        return shortcut
    }

    static func focusRightShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: focusRightKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return focusRightDefault
        }
        return shortcut
    }

    static func focusUpShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: focusUpKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return focusUpDefault
        }
        return shortcut
    }

    static func focusDownShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: focusDownKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return focusDownDefault
        }
        return shortcut
    }

    // MARK: - Split Action Accessors

    static func splitRightShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: splitRightKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return splitRightDefault
        }
        return shortcut
    }

    static func splitDownShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: splitDownKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return splitDownDefault
        }
        return shortcut
    }

    // MARK: - Bonsplit Tab Navigation Accessors

    static func nextBonsplitTabShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: nextBonsplitTabKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return nextBonsplitTabDefault
        }
        return shortcut
    }

    static func prevBonsplitTabShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: prevBonsplitTabKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return prevBonsplitTabDefault
        }
        return shortcut
    }

    static func newBonsplitTabShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: newBonsplitTabKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return newBonsplitTabDefault
        }
        return shortcut
    }

    // MARK: - Browser Accessors

    static func openBrowserShortcut() -> StoredShortcut {
        guard let data = UserDefaults.standard.data(forKey: openBrowserKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return openBrowserDefault
        }
        return shortcut
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: showNotificationsKey)
        UserDefaults.standard.removeObject(forKey: jumpToUnreadKey)
        UserDefaults.standard.removeObject(forKey: nextSidebarTabKey)
        UserDefaults.standard.removeObject(forKey: prevSidebarTabKey)
        UserDefaults.standard.removeObject(forKey: focusLeftKey)
        UserDefaults.standard.removeObject(forKey: focusRightKey)
        UserDefaults.standard.removeObject(forKey: focusUpKey)
        UserDefaults.standard.removeObject(forKey: focusDownKey)
        UserDefaults.standard.removeObject(forKey: splitRightKey)
        UserDefaults.standard.removeObject(forKey: splitDownKey)
        UserDefaults.standard.removeObject(forKey: nextBonsplitTabKey)
        UserDefaults.standard.removeObject(forKey: prevBonsplitTabKey)
        UserDefaults.standard.removeObject(forKey: newBonsplitTabKey)
        UserDefaults.standard.removeObject(forKey: openBrowserKey)
    }
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
        parts.append(key.uppercased())
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

    static func from(event: NSEvent) -> StoredShortcut? {
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let char = chars.first,
              char.isLetter || char.isNumber else {
            return nil
        }

        let flags = event.modifierFlags
        return StoredShortcut(
            key: String(char),
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
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

            return event
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
