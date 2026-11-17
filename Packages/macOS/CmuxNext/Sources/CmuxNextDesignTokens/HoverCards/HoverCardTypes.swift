public import Foundation

/// A thing that can have a hover card (a tab, a group chip, a sidebar
/// workspace row), named by a stable id, never by a view.
public nonisolated struct HoverTargetID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// What the reducer needs to know about a target: its id, its window and
/// how long the pointer must rest on it before its card shows, and what
/// leaving it does.
public nonisolated struct HoverTarget: Hashable, Sendable {
    public var id: HoverTargetID
    public var window: Int
    public var delay: Duration
    public var leave: HoverCardLeave
    /// Whether the pointer may move onto the shown card and keep it there (a sidebar row's card, whose
    /// rows and "Show details" take clicks). False: the card is only a preview, and the pointer on it
    /// counts as off its target, so moving off the target onto the card hides it as leaving does
    /// anywhere else (a horizontal tab's card, as in Chrome; user 2026-11-16: "for horizontal tabs i
    /// should not be able to hover mouse over horiztonal tab preview popover thing. for vertical tab
    /// preview, yes tho").
    public var enterable: Bool

    public init(id: HoverTargetID, window: Int, delay: Duration, leave: HoverCardLeave = .lingers, enterable: Bool = true) {
        self.id = id
        self.window = window
        self.delay = delay
        self.leave = leave
        self.enterable = enterable
    }
}

/// Ends any card at once and keeps cards away until the pointer moves.
public nonisolated enum HoverDismissal: String, Hashable, Sendable, CaseIterable {
    case keyDown, click, scrollWheel, menuOpened, windowResignedKey, appDeactivated, action
}
