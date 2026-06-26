/// Where a `cmux.json` action's terminal command runs: in the currently focused
/// terminal, or in a new tab created inside the current pane. Decodes from the
/// `target` string in an action definition.
public enum CmuxConfigTerminalCommandTarget: String, Codable, Sendable, Hashable {
    /// Run the command in the currently focused terminal surface.
    case currentTerminal
    /// Open a new tab in the current pane and run the command there.
    case newTabInCurrentPane

    /// The target applied to actions that do not declare an explicit `target`.
    public static let defaultForActions: CmuxConfigTerminalCommandTarget = .newTabInCurrentPane
}
