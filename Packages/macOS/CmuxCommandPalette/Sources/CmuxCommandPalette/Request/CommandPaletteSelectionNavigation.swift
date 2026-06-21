public import SwiftUI

/// The window-agnostic decision of whether a candidate selection-move delta
/// should be routed to the visible command palette.
///
/// The app target computes a candidate `delta` (`+1`/`-1`/`nil`) from the
/// keystroke, then asks whether the palette should handle it. Selection
/// navigation is routed only when the palette is interactive and is not
/// currently using inline text handling (a multiline editor consumes arrow
/// keys itself). Keeping this policy as a value type avoids a free function and
/// keeps it pure and testable.
public struct CommandPaletteSelectionNavigation: Sendable, Equatable {
    /// The candidate selection-move delta, or `nil` when the keystroke produced none.
    public let delta: Int?
    /// Whether the palette is currently interactive in the target window.
    public let isInteractive: Bool
    /// Whether the palette is routing the keystroke through an inline text editor.
    public let usesInlineTextHandling: Bool

    /// Creates a selection-navigation routing decision input.
    public init(delta: Int?, isInteractive: Bool, usesInlineTextHandling: Bool) {
        self.delta = delta
        self.isInteractive = isInteractive
        self.usesInlineTextHandling = usesInlineTextHandling
    }

    /// Whether the candidate delta should be routed to the palette.
    public var shouldRoute: Bool {
        guard delta != nil, isInteractive else { return false }
        return !usesInlineTextHandling
    }

    /// The command ID to anchor the selection on, for the result at
    /// `selectedIndex` within `resultIDs` (clamped into range), or `nil` when
    /// there are no results.
    public static func selectionAnchorCommandID(
        selectedIndex: Int,
        resultIDs: [String]
    ) -> String? {
        guard !resultIDs.isEmpty else { return nil }
        let resolvedIndex = min(max(selectedIndex, 0), resultIDs.count - 1)
        return resultIDs[resolvedIndex]
    }

    /// The scroll anchor that keeps `selectedIndex` visible: `.top` at the head,
    /// `.bottom` at the tail, `nil` (no forced scroll) in the middle or when the
    /// result list is empty.
    public static func scrollPositionAnchor(
        selectedIndex: Int,
        resultCount: Int
    ) -> UnitPoint? {
        guard resultCount > 0 else { return nil }
        if selectedIndex <= 0 { return UnitPoint.top }
        if selectedIndex >= resultCount - 1 { return UnitPoint.bottom }
        return nil
    }
}
