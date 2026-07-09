public import AppKit

/// The pointer/event context captured when an AppKit menu begins tracking,
/// used to decide whether that menu-tracking session should suppress a sidebar
/// row's hover-driven close button.
///
/// A right-click (or Control + left-click) that lands inside a row opens that
/// row's own context menu, and the hover state behind the open menu must not
/// keep showing the close button. A menu opened elsewhere, or via the keyboard,
/// must leave this row's hover state alone. The decision is a pure function of
/// the captured event, so it is modeled as a value type read through
/// ``suppressesCloseButton`` rather than a static utility.
public struct SidebarRowMenuTrackingContext: Equatable, Sendable {
    /// Whether the pointer was inside the row's bounds when the menu began
    /// tracking.
    public let pointerInsideRow: Bool
    /// The event type that triggered menu tracking, if any.
    public let eventType: NSEvent.EventType?
    /// The modifier flags active when the menu began tracking.
    public let modifierFlags: NSEvent.ModifierFlags

    /// Captures the menu-tracking event context for a sidebar row.
    /// - Parameters:
    ///   - pointerInsideRow: Whether the pointer was inside the row's bounds.
    ///   - eventType: The event type that triggered menu tracking, if any.
    ///   - modifierFlags: The modifier flags active at menu-tracking start.
    public init(
        pointerInsideRow: Bool,
        eventType: NSEvent.EventType?,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        self.pointerInsideRow = pointerInsideRow
        self.eventType = eventType
        self.modifierFlags = modifierFlags
    }

    /// True when this menu-tracking session should suppress the row's
    /// hover-driven close button: a pointer-driven context menu (right-click, or
    /// Control + left-click) opened inside the row.
    public var suppressesCloseButton: Bool {
        guard pointerInsideRow else { return false }

        switch eventType {
        case .some(.rightMouseDown), .some(.rightMouseUp):
            return true
        case .some(.leftMouseDown), .some(.leftMouseUp):
            return modifierFlags.contains(.control)
        default:
            return false
        }
    }
}
