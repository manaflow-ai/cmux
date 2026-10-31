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
    /// `home.channelsEnabled` is on (cx-frn2y): the Channels actions (Open Channels) are available.
    public static let homeChannelsEnabled = ActionContext(rawValue: 1 << 19)
    /// A web view has the keyboard, or had it last before the palette
    /// opened: a browser tab (WebKit or Chromium), the Markdown page, an
    /// agent chat, or any other `WKWebView` page. The Developer Tools
    /// commands (`devtools.*`) need it.
    public static let webViewFocused = ActionContext(rawValue: 1 << 20)
    /// A markdown page (with ``markdownFocused``) shows a file it cannot
    /// save: nothing in it takes typing, so it owns bare keys (K1, `g g`).
    public static let markdownReadOnlyFocused = ActionContext(rawValue: 1 << 21)
    /// A markdown page (with ``markdownFocused``) edits its file: bare keys
    /// are typing there.
    public static let markdownEditorFocused = ActionContext(rawValue: 1 << 22)
    /// Debug Settings' Side sessions (/btw) is on; Ask a Side Question… is offered only then.
    public static let sideSessions = ActionContext(rawValue: 1 << 23)

    /// Contexts whose page owns bare keys (no Command, Control or Option):
    /// only while one holds, and no text field has the keyboard, may a
    /// binding of a bare key run or a bare sequence arm (the diff viewer's
    /// j, k, G, /; a user's `g g` in a read-only markdown page). See ``KeyContext/ownsBareKeys``.
    public static let bareKeyOwners: ActionContext = [.diffViewerFocused, .markdownReadOnlyFocused]
}

extension ActionContext {
    /// A focused markdown page's bits: ``markdownFocused``, and whether it shows a file it
    /// cannot save (``markdownReadOnlyFocused``, which owns bare keys) or edits it.
    public nonisolated static func markdown(readOnly: Bool) -> ActionContext {
        [.markdownFocused, readOnly ? .markdownReadOnlyFocused : .markdownEditorFocused]
    }

    /// Context facts an invocation's explicit target stands in for: a
    /// `machine:` target is the Cloud workspace a focus-scoped machine
    /// action would otherwise need focused, and an `agent-chat:` target the
    /// focused agent chat (Archive Chat on a Priority row).
    public static func implied(by invocation: ActionInvocation) -> ActionContext {
        implied(byTargetKind: invocation.target?.kind)
    }

    public nonisolated static func implied(byTargetKind kind: ActionTargetKind?) -> ActionContext {
        switch kind {
        case .machine: .cloudWorkspace
        case .agentChat: .agentPaneFocused
        default: []
        }
    }

    /// The facts a `pane:` or `tab:` target brings itself (`ActionRegistry.targetContext`):
    /// whether it is an agent chat, and whether it sits on a canvas screen.
    public nonisolated static let decidedByPaneOrTabTarget: ActionContext = [.agentPaneFocused, .canvasLayout]
}
