/// When the terminal Files chip is on screen, given that it is mounted and the
/// docked toolbar is showing.
///
/// A paired Mac's chip counts file paths on screen and sits over terminal
/// text, so it is scroll-revealed like a scroll indicator. An SSH computer's
/// chip is the only way into its file browser (PRD D28); a command with no
/// other entry point must stay visible rather than wait for a scroll.
public enum TerminalFilesChipReveal: Equatable, Sendable {
    /// Shown while the user scrolls, then faded after a linger.
    case onScroll
    /// Shown whenever it is mounted.
    case always

    /// Whether the chip shows. Assistive technologies cannot reasonably scroll
    /// to reveal it, so they always see it.
    public func isVisible(scrollRevealed: Bool, assistiveTechnologyRunning: Bool) -> Bool {
        switch self {
        case .always: true
        case .onScroll: scrollRevealed || assistiveTechnologyRunning
        }
    }
}
