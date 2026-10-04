/// One value of a context key (plans/cmux-next/keybindings.md section 4).
public nonisolated enum KeyContextValue: Hashable, Sendable {
    case bool(Bool)
    case string(String)
    case number(Double)
    /// A list, for `in` (`key in listKey`).
    case strings([String])

    /// Truthiness as in a `when` clause: false, "", 0 and [] are false.
    public var isTruthy: Bool {
        switch self {
        case .bool(let value): value
        case .string(let value): !value.isEmpty
        case .number(let value): value != 0
        case .strings(let values): !values.isEmpty
        }
    }

    /// The text `==`, `!=` and `=~` compare.
    public var text: String {
        switch self {
        case .bool(let value): value ? "true" : "false"
        case .string(let value): value
        case .number(let value): value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .strings(let values): values.joined(separator: ",")
        }
    }
}

/// The live context keys of one window: what `when` clauses read. Built
/// per key-down from the focus of the window the key goes to (never from
/// another window's focus) plus the facts that do not depend on focus.
public nonisolated struct KeyContext: Hashable, Sendable {
    public private(set) var values: [String: KeyContextValue]

    public init(_ values: [String: KeyContextValue] = [:]) {
        self.values = values
    }

    /// The legacy context bits as boolean keys (`terminalFocused`, ...).
    public init(bits: ActionContext) {
        values = [:]
        for (bit, name) in ActionContext.keyNames where bits.contains(bit) { values[name] = .bool(true) }
    }

    public subscript(_ key: String) -> KeyContextValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    /// The legacy bits these keys hold (availability checks use them).
    public var bits: ActionContext {
        var bits: ActionContext = []
        for (bit, name) in ActionContext.keyNames where values[name]?.isTruthy == true { bits.insert(bit) }
        return bits
    }

    // MARK: Built-in key names

    /// What has the keyboard: `terminal`, `page` (a web page), `agent`,
    /// `home`, `settings`, `appStore`, another internal page's id, `empty`
    /// (a pane with no content) or `palette`. Absent outside a pane.
    public static let surfaceKind = "surfaceKind"
    /// The keyboard target: `content`, `omnibar`, `findBar`, `devTools`,
    /// `sidebar`, `sidebarField`, `textField`, `overlay`, `none`.
    public static let focus = "focus"
    /// A text field has the keyboard (address bar, find bar, sidebar
    /// field, rename sheet, other fields).
    public static let textInputFocus = "textInputFocus"
    /// The focused page is in browser focus mode.
    public static let browserFocusMode = "browserFocusMode"
    /// The focused terminal is in copy mode.
    public static let terminalCopyMode = "terminal.copyMode"
    /// The kind of window the key goes to (``WindowKindValue``).
    public static let windowKind = "windowKind"

    /// Values of ``windowKind``.
    public struct WindowKindValue {
        public init() {}
        /// A cmux main window (or a Chromium page window over it).
        public static let main = "main"
        /// A browser popup panel (or its page window).
        public static let browserPopup = "browserPopup"
    }
}

extension ActionContext {
    /// Context key names of the legacy bits, as `when` clauses write them.
    public nonisolated static let keyNames: [(ActionContext, String)] = [
        (.terminalFocused, "terminalFocused"), (.browserFocused, "browserFocused"), (.canvasLayout, "canvasLayout"),
        (.simulatorFocused, "simulatorFocused"), (.diffViewerFocused, "diffViewerFocused"),
        (.filePreviewFocused, "filePreviewFocused"), (.markdownFocused, "markdownFocused"),
        (.rightSidebarFocused, "rightSidebarFocused"), (.fileExplorerFocused, "fileExplorerFocused"),
        (.textBoxFocused, "textBoxFocused"), (.paletteOpen, "paletteOpen"), (.signedIn, "signedIn"),
        (.signedOut, "signedOut"), (.cloudWorkspace, "cloudWorkspace"), (.agentPaneFocused, "agentPaneFocused"),
        (.checkpointCaptureAvailable, "checkpointCaptureAvailable"), (.recordingShortcut, "recordingShortcut"),
        (.omnibarFocused, "omnibarFocused"),
    ]

    /// The bits a window's focus decides; the rest are app-wide facts.
    public nonisolated static let focusBits: ActionContext = [.terminalFocused, .browserFocused, .agentPaneFocused, .omnibarFocused]
}
