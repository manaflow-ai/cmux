public import Foundation

/// A thing that can have a hover card (a tab, a group chip, a sidebar
/// workspace row), named by a stable id, never by a view.
public nonisolated struct HoverTargetID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// What the reducer needs to know about a target: its id, its window and
/// how long the pointer must rest on it before its card shows.
public nonisolated struct HoverTarget: Hashable, Sendable {
    public var id: HoverTargetID
    public var window: Int
    public var delay: Duration

    public init(id: HoverTargetID, window: Int, delay: Duration) {
        self.id = id
        self.window = window
        self.delay = delay
    }
}

/// Ends any card at once and keeps cards away until the pointer moves.
public nonisolated enum HoverDismissal: String, Hashable, Sendable, CaseIterable {
    case keyDown, click, scrollWheel, menuOpened, windowResignedKey, appDeactivated, action
}
