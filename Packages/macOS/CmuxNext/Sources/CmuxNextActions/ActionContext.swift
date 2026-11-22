/// Surfaces where the old app exposed an action (inventory legend P/K/M/C).
/// Informational: menus and context menus in cmux-next are built by the App.
public nonisolated struct ActionSurfaces: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let palette = ActionSurfaces(rawValue: 1 << 0)
    public static let keyboard = ActionSurfaces(rawValue: 1 << 1)
    public static let menu = ActionSurfaces(rawValue: 1 << 2)
    public static let contextMenu = ActionSurfaces(rawValue: 1 << 3)
}

/// Focus and session facts the App publishes to the registry. A descriptor's
/// `requires` must be a subset of the current context for the action to be
/// available, which is also how conflicting default shortcuts (for example
/// Cmd-[ for focus history and browser back) resolve.
public nonisolated struct ActionContext: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let terminalFocused = ActionContext(rawValue: 1 << 0)
    public static let browserFocused = ActionContext(rawValue: 1 << 1)
    public static let canvasLayout = ActionContext(rawValue: 1 << 2)
    public static let simulatorFocused = ActionContext(rawValue: 1 << 3)
    public static let diffViewerFocused = ActionContext(rawValue: 1 << 4)
    public static let filePreviewFocused = ActionContext(rawValue: 1 << 5)
    public static let markdownFocused = ActionContext(rawValue: 1 << 6)
    public static let rightSidebarFocused = ActionContext(rawValue: 1 << 7)
    public static let fileExplorerFocused = ActionContext(rawValue: 1 << 8)
    public static let textBoxFocused = ActionContext(rawValue: 1 << 9)
    public static let paletteOpen = ActionContext(rawValue: 1 << 10)
    public static let signedIn = ActionContext(rawValue: 1 << 11)
    public static let signedOut = ActionContext(rawValue: 1 << 12)
    public static let cloudWorkspace = ActionContext(rawValue: 1 << 13)
    /// An agent chat (the acpmux web pane) has the keyboard.
    public static let agentPaneFocused = ActionContext(rawValue: 1 << 14)
    /// The focused agent page can capture through its session-host Git connection.
    public static let checkpointCaptureAvailable = ActionContext(rawValue: 1 << 15)
    /// A shortcut recorder (Settings or the palette's Cmd-K editor) is open;
    /// system-wide hot keys stand down so it can record their chords.
    public static let recordingShortcut = ActionContext(rawValue: 1 << 16)
    /// A browser tab's address bar has the keyboard. Its Return chords
    /// (Cmd-Return: open in a new tab) need it, so they beat the actions
    /// that share those chords elsewhere (Toggle Pane Zoom).
    public static let omnibarFocused = ActionContext(rawValue: 1 << 17)
    /// The code editor page (Monaco, `cmux.editor`) has the keyboard: its
    /// editing chords win over the app chords that share them (R127).
    public static let codeEditorFocused = ActionContext(rawValue: 1 << 18)

    /// Contexts whose page owns bare keys (no Command, Control or Option):
    /// only while one holds, and no text field has the keyboard, may a
    /// binding of a bare key run (the diff viewer's j, k, G, /).
    public static let bareKeyOwners: ActionContext = [.diffViewerFocused]
}

extension ActionContext {
    /// Context facts an invocation's explicit target stands in for: a
    /// `machine:` target is the Cloud workspace a focus-scoped machine
    /// action would otherwise need focused.
    public static func implied(by invocation: ActionInvocation) -> ActionContext {
        implied(byTargetKind: invocation.target?.kind)
    }

    public nonisolated static func implied(byTargetKind kind: ActionTargetKind?) -> ActionContext {
        kind == .machine ? .cloudWorkspace : []
    }
}
