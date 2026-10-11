public import AppKit

/// What else a chord may mean where an action's shortcut runs, supplied by
/// the App: the user's Ghostty keybinds and the browser chords that have a
/// meaning in a web page (plans/cmux-next/focus.md section 5).
public struct ShortcutEditEnvironment: Sendable {
    /// The cmux action title a Ghostty keybind for this chord maps to, or
    /// the Ghostty action name; nil when Ghostty does not bind it.
    public var ghosttyBinding: @MainActor @Sendable (Shortcut) -> String?
    /// The browser chords a page keeps (`BrowserChordTable.chromeReserved`).
    public var chromeChords: Set<Shortcut>

    public init(ghosttyBinding: @escaping @MainActor @Sendable (Shortcut) -> String? = { _ in nil }, chromeChords: Set<Shortcut> = []) {
        self.ghosttyBinding = ghosttyBinding
        self.chromeChords = chromeChords
    }
}

/// Chords macOS keeps for itself; an app never sees them, or taking them
/// breaks a system feature.
public struct SystemReservedShortcuts {
    public static let shared = Self()
    public let table: [Shortcut: String] = [
        Shortcut(" ", modifiers: [.command]): "Spotlight",
        Shortcut(" ", modifiers: [.command, .option]): "Finder search",
        Shortcut(" ", modifiers: [.control]): "Input Sources",
        Shortcut(" ", modifiers: [.control, .command]): "Emoji & Symbols",
        Shortcut("\t", modifiers: [.command]): "App Switcher",
        Shortcut("\t", modifiers: [.command, .shift]): "App Switcher",
        Shortcut("`", modifiers: [.command]): "Cycle Windows",
        Shortcut("`", modifiers: [.command, .shift]): "Cycle Windows",
        Shortcut("3", modifiers: [.command, .shift]): "Screenshot",
        Shortcut("4", modifiers: [.command, .shift]): "Screenshot",
        Shortcut("5", modifiers: [.command, .shift]): "Screenshot",
        Shortcut("6", modifiers: [.command, .shift]): "Screenshot",
        Shortcut("\u{1B}", modifiers: [.command, .option]): "Force Quit",
        Shortcut("q", modifiers: [.control, .command]): "Lock Screen",
        Shortcut("h", modifiers: [.command]): "Hide cmux",
        Shortcut("h", modifiers: [.command, .option]): "Hide Others",
        Shortcut("m", modifiers: [.command]): "Minimize",
        Shortcut("d", modifiers: [.command, .option]): "Dock",
        Shortcut("f", modifiers: [.control, .command]): "Full Screen",
        Shortcut(",", modifiers: [.command]): "Settings",
        Shortcut(Shortcut.upArrowKey, modifiers: [.control]): "Mission Control",
        Shortcut(Shortcut.downArrowKey, modifiers: [.control]): "App Exposé",
        Shortcut(Shortcut.leftArrowKey, modifiers: [.control]): "Move Space",
        Shortcut(Shortcut.rightArrowKey, modifiers: [.control]): "Move Space",
    ]
}
