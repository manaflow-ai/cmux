import CoreGraphics

/// Where an agent runs: a GUI agent chat (an acpmux session in a chat pane), or a terminal agent
/// (Claude Code or Codex in a terminal tab, as a hook reports it). Both draw the same brand mark;
/// the container the mark sits on tells them apart (Leo, 2026-11-24: "terminal agent chats. can
/// they be demarcated a bit differently/should they? than gui agent chats. both of them rn are
/// just claude icon"). A chat's mark sits on a circle; a terminal agent's on a rounded square, the
/// shape of a terminal window, with no badge or extra glyph added to the mark.
///
/// The iOS app (Feed rows, the peek header) and the Mac (tab strip, tab hover card) share this one
/// rule, so the two read alike.
public enum AgentRunSurface: String, Sendable, Hashable, CaseIterable {
    case chat
    case terminal

    /// The surface of an agent: `true` when it runs in a terminal.
    public init(inTerminal: Bool) {
        self = inTerminal ? .terminal : .chat
    }

    /// The container's corner radius as a share of its side: a circle (0.5) for a chat, a
    /// rounded square for a terminal. 0.3 reads as a square at 16 pt and still as a tile, not a
    /// circle, at 40 pt (the gallery's sizes, `-cmux-mobile-recovery-gallery agentmark`).
    public var cornerShare: CGFloat {
        switch self {
        case .chat: 0.5
        case .terminal: 0.3
        }
    }

    /// The corner radius of a container `side` points across.
    public func cornerRadius(side: CGFloat) -> CGFloat {
        (side * cornerShare).rounded(.toNearestOrAwayFromZero)
    }

    /// The words an accessibility label adds after the agent's name ("Claude, in a terminal");
    /// empty for a chat, which is what an agent's name alone already means.
    public var spokenSuffix: String {
        switch self {
        case .chat: ""
        case .terminal: "in a terminal"
        }
    }
}
