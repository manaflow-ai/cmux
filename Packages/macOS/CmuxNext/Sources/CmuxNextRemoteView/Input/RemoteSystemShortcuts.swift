public import AppKit
public import CoreGraphics

/// One key event the system shortcut tap saw: a key down or up with its
/// modifiers (`flagsChanged` is not one: modifiers reach the capture view).
public nonisolated struct RemoteTapKey: Sendable, Equatable {
    public var keyCode: UInt16
    public var modifiers: NSEvent.ModifierFlags
    public var down: Bool
    public var isRepeat: Bool

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, down: Bool, isRepeat: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift])
        self.down = down
        self.isRepeat = isRepeat
    }

    /// A key down or up from an event tap; nil for any other event.
    public init?(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown, .keyUp: break
        default: return nil
        }
        self.init(keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                  // The device-independent bits of CGEventFlags are NSEvent's modifier flags.
                  modifiers: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
                  down: type == .keyDown,
                  isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    }
}

/// "Send System Shortcuts to the Remote Mac": which chords a session event
/// tap takes from macOS while a remote screen has the keyboard, and when the
/// tap may exist at all. Pure: the tap and the Mac Screen pages ask it.
public nonisolated struct RemoteSystemShortcuts: Sendable, Equatable {
    /// What must all hold for the tap to be installed.
    public nonisolated struct Conditions: Sendable, Equatable {
        /// The person's setting (`macScreen.systemShortcuts`).
        public var setting = false
        /// This app is trusted for Accessibility (a session tap needs it).
        public var accessibility = false
        /// A remote screen has the keyboard (focused, control mode, not released).
        public var hasKeyboard = false
        /// Its session is connected.
        public var live = false
        /// Its window is the key window.
        public var windowKey = false
        /// This app is the active app.
        public var appActive = false

        public init(setting: Bool = false, accessibility: Bool = false, hasKeyboard: Bool = false, live: Bool = false,
                    windowKey: Bool = false, appActive: Bool = false) {
            self.setting = setting
            self.accessibility = accessibility
            self.hasKeyboard = hasKeyboard
            self.live = live
            self.windowKey = windowKey
            self.appActive = appActive
        }
    }

    /// The chord that gives the keyboard back: never taken.
    public var releaseChord = RemoteReleaseChord.default
    /// Keys whose down the tap took: their ups are taken too.
    public private(set) var heldByTap: Set<UInt16> = []

    public init() {}

    /// Whether the tap is installed under `conditions`.
    public func installs(_ conditions: Conditions) -> Bool {
        conditions.setting && conditions.accessibility && conditions.hasKeyboard && conditions.live
            && conditions.windowKey && conditions.appActive
    }

    /// Whether the tap takes a key down with `modifiers`.
    ///
    /// The list: Spotlight and input sources (Cmd-Space, Cmd-Option-Space,
    /// Control-Space), app and window switching (Cmd-Tab, Cmd-`, with
    /// Shift), Mission Control, App Windows and Spaces (Control-arrows),
    /// screenshots (Cmd-Shift-3/4/5, with Control), Lock Screen (Control-Cmd-Q),
    /// and the app chords Cmd-Q, Cmd-W, Cmd-H, Cmd-M (with Option, and
    /// Cmd-Shift-Q). Precedence: the list goes to the other Mac even where
    /// it is also a cmux binding (Cmd-W closes the remote window, not the
    /// tab); every other chord keeps the capture view's rule, so cmux's own
    /// shortcuts stay here. The release chord is never taken, even when a
    /// person rebinds it onto the list. Keys with no HID usage (the Mission
    /// Control and Launchpad keys) cannot be sent and stay with macOS.
    public func takes(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        if releaseChord.matches(keyCode: keyCode, modifiers: flags) { return false }
        guard RemoteHIDKeyMap().usage(forKeyCode: keyCode) != nil else { return false }
        typealias Code = RemoteKeyboardPolicy.KeyCode
        switch keyCode {
        case Code.space:
            return flags == .command || flags == [.command, .option] || flags == .control || flags == [.control, .option]
        case Code.tab, Code.grave:
            return flags == .command || flags == [.command, .shift]
        case Code.leftArrow, Code.rightArrow, Code.upArrow, Code.downArrow:
            return flags == .control
        case Self.three, Self.four, Self.five:
            return flags == [.command, .shift] || flags == [.command, .shift, .control]
        case Code.q:
            return flags == .command || flags == [.command, .option] || flags == [.command, .shift] || flags == [.command, .control]
        case Code.h, Code.m, Self.w:
            return flags == .command || flags == [.command, .option]
        default:
            return false
        }
    }

    private static let three: UInt16 = 0x14
    private static let four: UInt16 = 0x15
    private static let five: UInt16 = 0x17
    private static let w: UInt16 = 0x0D

    /// The events to send for `key`, recorded in `keyboard`; nil when the
    /// tap lets the key go on to macOS and the app.
    public mutating func route(_ key: RemoteTapKey, keyboard: inout RemoteKeyboardState) -> [RemoteInputEvent]? {
        if key.down {
            guard heldByTap.contains(key.keyCode) || takes(keyCode: key.keyCode, modifiers: key.modifiers) else { return nil }
            heldByTap.insert(key.keyCode)
            return keyboard.keyDown(keyCode: key.keyCode, isRepeat: key.isRepeat)
        }
        guard heldByTap.remove(key.keyCode) != nil else { return nil }
        return keyboard.keyUp(keyCode: key.keyCode)
    }

    /// The key's up reached the capture view instead of the tap (the tap was removed).
    public mutating func keyWentUp(_ keyCode: UInt16) { heldByTap.remove(keyCode) }

    /// Everything was released (focus lost, release chord).
    public mutating func reset() { heldByTap.removeAll() }
}
