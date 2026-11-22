public import AppKit

/// One key event the system shortcut tap took: a key down or up with its modifiers
/// (`flagsChanged` is not one: modifiers reach the capture view). The tap runs in the Screen
/// Sharing helper (cmux-rd-host `src/shortcut_tap.rs`), which decides which keys it takes.
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
}

/// "Send System Shortcuts to the Remote Mac": when the session event tap may take keys at all.
/// Which chords it takes is the helper's (cmux-rd-host `shortcut_tap::takes`), decided in the
/// tap's own callback. Pure: the Mac Screen pages ask it.
public nonisolated struct RemoteSystemShortcuts: Sendable, Equatable {
    /// What must all hold for the tap to take keys.
    public nonisolated struct Conditions: Sendable, Equatable {
        /// The person's setting (`macScreen.systemShortcuts`).
        public var setting = false
        /// The Screen Sharing helper, where the tap runs, is trusted for Accessibility.
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

    public init() {}

    /// Whether the tap takes keys under `conditions`.
    public func installs(_ conditions: Conditions) -> Bool {
        conditions.setting && conditions.accessibility && conditions.hasKeyboard && conditions.live
            && conditions.windowKey && conditions.appActive
    }
}
