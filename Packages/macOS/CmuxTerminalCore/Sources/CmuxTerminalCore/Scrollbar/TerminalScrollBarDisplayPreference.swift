/// The macOS scrollbar visibility preferences used by a terminal scroll view.
public enum TerminalScrollBarDisplayPreference: Equatable, Sendable {
    /// Reveal the scrollbar while the pointer is over it or while scrolling.
    case automatic

    /// Reveal the scrollbar only while actively scrolling.
    case whenScrolling

    /// Keep the scrollbar visible whenever the terminal scrollbar is enabled.
    case always
}
