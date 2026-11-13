public import CmuxNextIcons
public import CoreGraphics

/// Leading icon of a tab.
public enum TabIcon: Hashable, Sendable {
    case none
    /// An SF Symbol name, tinted to the tab's text color.
    case symbol(String)
    /// A cmux icon registry name (CmuxNextIcons), drawn from the active pack
    /// at the full icon box and tinted to the tab's text color.
    case icon(IconName)
    /// A full-color image such as a favicon. Drawn as is.
    case image(TabImage)
    /// An agent's brand mark (a CmuxAgentBrands brand id such as "claude"),
    /// tinted to the tab's text color like a symbol.
    case agentMark(String)
}

public extension TabIcon {
    /// A terminal tab's kind icon: the bare `>_` (`tab.terminal`), not the framed `terminal`.
    /// Tab icons draw at 12 to 20 pt, where the frame crowds the prompt (Leo 2026-11-07).
    nonisolated static let terminal = TabIcon.icon(.tabTerminal)
    /// An exited terminal tab's kind icon (`tab.terminal.dead`).
    nonisolated static let terminalDead = TabIcon.icon(.tabTerminalDead)
    /// A browser tab's icon until its favicon loads: the globe with fewer lines (`tab.browser`).
    nonisolated static let browser = TabIcon.icon(.tabBrowser)
}

/// A full-color tab image (favicon). Compared by identity so that updating
/// a tab with the same image object does not redraw it.
public final class TabImage: Hashable, @unchecked Sendable {
    // CGImage is immutable once created, which makes the unchecked Sendable sound.
    public let cgImage: CGImage

    public init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }

    public static func == (lhs: TabImage, rhs: TabImage) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Agent or process status shown as a small colored dot at the tab's trailing end (TabCell+TrailingMarks).
/// A status dot takes priority over the neutral unread dot.
public enum TabStatus: Hashable, Sendable {
    case none
    case needsInput
    case success
    case failure
}
