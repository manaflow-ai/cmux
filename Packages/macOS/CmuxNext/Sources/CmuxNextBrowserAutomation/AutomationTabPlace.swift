/// Where a browser session's new tab opens: beside the session's caller.
///
/// The browser host fills it on `tabs.open` from what the caller's client
/// stated when the session opened (`callerWorkspace`, from
/// `CMUX_WORKSPACE_ID`; `callerTerminal`, from `CMUX_TUI_TERMINAL_ID`). The
/// app opens the tab in the caller's own workspace, never the focused one;
/// with neither field it falls back to the focused pane.
public nonisolated struct AutomationTabPlace: Sendable, Equatable {
    /// The caller's workspace key, or nil.
    public var workspace: String?
    /// The caller's terminal id (`term_…`), or nil.
    public var terminal: String?

    /// A place from its two fields.
    ///
    /// - Parameters:
    ///   - workspace: The caller's workspace key, or nil.
    ///   - terminal: The caller's terminal id, or nil.
    public init(workspace: String? = nil, terminal: String? = nil) {
        self.workspace = workspace
        self.terminal = terminal
    }

    /// The place a `tabs.open` call's params name (`callerWorkspace`,
    /// `callerTerminal`); a field that is not a non-empty string is ignored.
    ///
    /// - Parameter params: The call's params.
    public init(_ params: DriverJSON) {
        func field(_ key: String) -> String? {
            guard case .object(let fields) = params, case .string(let value)? = fields[key], !value.isEmpty else { return nil }
            return value
        }
        self.init(workspace: field("callerWorkspace"), terminal: field("callerTerminal"))
    }
}
