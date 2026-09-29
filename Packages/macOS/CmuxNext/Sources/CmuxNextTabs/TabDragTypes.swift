public import CoreGraphics
public import Foundation

/// Everything the App's drag session needs when a tab leaves its strip.
public struct TabDragStart: Equatable, Sendable {
    public var tabID: TabID
    public var stripID: UUID
    /// Screen frame of the tab at hand-off.
    public var screenFrame: CGRect
    /// Pointer position inside the tab (screen orientation, bottom-left origin).
    public var grabOffset: CGPoint
    public var screenPoint: CGPoint
    /// Image of the tab itself. The session may prefer a content thumbnail.
    public var snapshot: TabImage?
}

/// Result of hit-testing a strip during an external drag.
public struct TabStripDropTarget: Equatable, Sendable {
    public var stripID: UUID
    /// Final index in `orderedTabs` (without a tab handed off from this strip).
    public var index: Int
    /// Screen frame of the inline slot for the ghost.
    public var ghostFrame: CGRect
}
