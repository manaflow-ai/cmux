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
        nil
    }
}

/// "Send System Shortcuts to the Remote Mac": which chords a session event
/// tap takes from macOS while a remote screen has the keyboard, and when the
/// tap may exist at all. Pure: the tap and the Mac Screen pages ask it.
public nonisolated struct RemoteSystemShortcuts: Sendable, Equatable {
    /// What must all hold for the tap to be installed.
    public struct Conditions: Sendable, Equatable {
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
        false
    }

    /// Whether the tap takes a key down with `modifiers`.
    public func takes(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        false
    }

    /// The events to send for `key`, recorded in `keyboard`; nil when the
    /// tap lets the key go on to macOS and the app.
    public mutating func route(_ key: RemoteTapKey, keyboard: inout RemoteKeyboardState) -> [RemoteInputEvent]? {
        nil
    }

    /// Everything was released (focus lost, release chord).
    public mutating func reset() { heldByTap.removeAll() }
}
