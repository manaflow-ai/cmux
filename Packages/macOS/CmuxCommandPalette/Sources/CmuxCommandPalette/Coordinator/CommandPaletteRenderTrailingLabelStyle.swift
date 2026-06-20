/// Visual style of a command-palette result row's trailing label.
public enum CommandPaletteRenderTrailingLabelStyle: Equatable, Sendable {
    /// The label is a keyboard-shortcut hint (e.g. `⌘K`).
    case shortcut
    /// The label is a command-kind descriptor (e.g. `Workspace`).
    case kind
}
