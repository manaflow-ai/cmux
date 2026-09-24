/// The two AppKit scrollbar styles that differ in whether they reserve layout space.
public enum TerminalScrollerStyle: Equatable, Sendable {
    /// The classic scrollbar reserves a fixed trailing gutter in the terminal grid.
    case legacy

    /// The overlay scrollbar draws over content and reserves no layout space.
    case overlay
}
