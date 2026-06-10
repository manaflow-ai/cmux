public import Foundation

/// The pre-parsed inputs for `workspace.create`, carried across
/// ``ControlWorkspaceContext`` so the seam runs the app-typed remainder (the
/// `cwd`-type / `layout` decode validation, the `addWorkspace` call) on live
/// state.
///
/// The coordinator parses every scalar/string/map param exactly as the legacy
/// body did, but defers the `cwd` string-type check and the `layout` JSON
/// decode to the conformance because both require app types
/// (`JSONSerialization` shape / `CmuxLayoutNode`). The raw `cwd` and `layout`
/// values are passed through as ``JSONValue`` so the app can reproduce the
/// identical `invalid_params` failures and the `NSNull`/missing distinction.
public struct ControlWorkspaceCreateInputs: Sendable, Equatable {
    /// The resolved title, or `nil` (legacy: trimmed, empty → nil).
    public let title: String?
    /// The resolved description (untrimmed raw string), or `nil`.
    public let description: String?
    /// The resolved `working_directory` override, or `nil` (trimmed, empty →
    /// nil). When present it wins over `cwd`.
    public let workingDirectory: String?
    /// The raw `cwd` param value, if the key was present (may be non-string,
    /// which the app rejects). Absent key → `nil`.
    public let rawCWD: JSONValue?
    /// The resolved `initial_command`, or `nil`.
    public let initialCommand: String?
    /// The resolved `initial_env` map (trimmed keys, empties dropped).
    public let initialEnv: [String: String]
    /// The raw `layout` param value, if present (decoded app-side). Absent →
    /// `nil`.
    public let rawLayout: JSONValue?
    /// The requested `focus` flag, defaulted to `false` (the app runs it through
    /// its `v2FocusAllowed` gate, which also drives the `eagerLoadTerminal`
    /// default).
    public let focusRequested: Bool
    /// The parsed `eager_load_terminal` override, or `nil` when absent (legacy
    /// default `!shouldFocus`, computed app-side).
    public let eagerLoadTerminal: Bool?
    /// The parsed `auto_refresh_metadata` override, or `nil` when absent (legacy
    /// default `true`).
    public let autoRefreshMetadata: Bool?

    /// Creates the create inputs.
    public init(
        title: String?,
        description: String?,
        workingDirectory: String?,
        rawCWD: JSONValue?,
        initialCommand: String?,
        initialEnv: [String: String],
        rawLayout: JSONValue?,
        focusRequested: Bool,
        eagerLoadTerminal: Bool?,
        autoRefreshMetadata: Bool?
    ) {
        self.title = title
        self.description = description
        self.workingDirectory = workingDirectory
        self.rawCWD = rawCWD
        self.initialCommand = initialCommand
        self.initialEnv = initialEnv
        self.rawLayout = rawLayout
        self.focusRequested = focusRequested
        self.eagerLoadTerminal = eagerLoadTerminal
        self.autoRefreshMetadata = autoRefreshMetadata
    }
}
