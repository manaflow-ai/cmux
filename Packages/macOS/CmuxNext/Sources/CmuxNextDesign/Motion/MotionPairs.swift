public import CmuxNextDesignTokens
public import Foundation

/// A motion that brings a thing in and the motion that takes it away again. The exit of a pair ends
/// sooner than its enter: a person waits for what arrives and not for what leaves. ``all`` is the one
/// list of the pairs, so one test reads every pair at every speed (`MotionCapTests`).
///
/// A token with no enter of ours is in no pair: the window close fade (`MotionSpring.exit`) undoes a
/// window open that AppKit draws.
public nonisolated struct MotionPair: Sendable, Equatable {
    /// One side of a pair: a spring, a fade or a tween token.
    public nonisolated enum Side: Sendable, Equatable {
        case spring(MotionSpring)
        case fade(MotionFade)
        case tween(MotionTween)
    }

    /// What the pair is, in words (a test names its cases by it).
    public let name: String
    /// The motion that brings the thing in.
    public let enter: Side
    /// The motion that takes it away.
    public let exit: Side
    /// Why the exit takes as long as the enter; nil when the exit is the shorter one.
    public let equalBecause: String?

    init(_ name: String, enter: Side, exit: Side, equalBecause: String? = nil) {
        self.name = name
        self.enter = enter
        self.exit = exit
        self.equalBecause = equalBecause
    }

    /// A split's new pane growing in while its chain makes room; a closing pane's neighbours growing
    /// over it (`PaneMotionVariant.splitSpring`, `closeSpring`).
    public static let pane = MotionPair("pane split and close", enter: .spring(.split), exit: .spring(.paneClose))
    /// A pane zooming to fill its screen; the same pane going back (`PaneMotionVariant.expandSpring`,
    /// `restoreSpring`).
    public static let zoom = MotionPair("pane zoom and unzoom", enter: .spring(.zoom), exit: .spring(.unzoom))
    /// A row, a group, a sidebar or a tab's title showing; the same thing hiding.
    public static let appear = MotionPair("appear and disappear", enter: .spring(.appear), exit: .spring(.disappear))
    /// A popup growing out of its control; the same popup shrinking back.
    public static let popup = MotionPair("popup open and close", enter: .spring(.popover), exit: .spring(.popoverClose))
    /// A view or a panel fading in; the same thing fading out.
    public static let fade = MotionPair("fade in and out", enter: .fade(.fadeIn), exit: .fade(.fadeOut))
    /// A tab opening on the strip; a tab closing.
    public static let tab = MotionPair(
        "tab open and close", enter: .tween(.tabOpen), exit: .tween(.tabClose),
        equalBecause: "a strip change is one tween for every tab: the tab that opens or closes and the tabs that make or take room move on one clock, and the open and the close use the same one")

    /// Every pair.
    public static let all: [MotionPair] = [pane, zoom, appear, popup, fade, tab]
}

nonisolated extension MotionPolicy {
    /// Seconds until `side` ends visibly under this policy: a spring's visible end, a fade's or a
    /// tween's duration. 0 when it applies at once.
    public func seconds(_ side: MotionPair.Side) -> TimeInterval {
        switch side {
        case .spring(let token): duration(token)
        case .fade(let token): duration(token)
        case .tween(let token): duration(token)
        }
    }
}
