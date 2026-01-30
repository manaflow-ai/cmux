import AppKit
import SwiftUI

/// Stores customizable keyboard shortcuts
enum KeyboardShortcutSettings {
    static let showNotificationsKey = "shortcut.showNotifications"
    static let jumpToUnreadKey = "shortcut.jumpToUnread"

    /// Default shortcut: Cmd+Shift+I
    static let showNotificationsDefault = StoredShortcut(key: "i", command: true, shift: true, option: false, control: false)
    /// Default shortcut: Cmd+Shift+U
    static let jumpToUnreadDefault = StoredShortcut(key: "u", command: true, shift: true, option: false, control: false)

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

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: showNotificationsKey)
        UserDefaults.standard.removeObject(forKey: jumpToUnreadKey)
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
