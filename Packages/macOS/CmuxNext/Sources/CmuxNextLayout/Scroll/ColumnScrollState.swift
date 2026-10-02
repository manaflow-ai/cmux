public import CoreGraphics
public import CmuxNextDesign
public import Foundation

/// Scroll state of one columns screen: the spring the view presents, the
/// strip it was computed for, the focus it follows, and a live trackpad
/// gesture. Changed only by `reduce(_:)` (ColumnScrollReducer.swift); the
/// view steps the spring each display frame. plans/cmux-next/column-scroll.md.
public nonisolated struct ColumnScrollState: Hashable, Sendable {
    /// `value` is presented, `target` is where it settles. Offsets are the
    /// content-space x of the viewport's leading edge.
    public var spring = SpringValue(0)
    public var strip: ColumnStrip?
    public var focusedPane: PaneID?
    public var focusedColumn: ColumnID?
    public var mode: CenterFocusedColumn = .never
    public var gesture: Gesture?
    /// Restore point: a column opened right of the
    /// focused one and focused; closing it returns to this offset.
    public var restore: RestorePoint?
    /// Last focused pane per column, for focus moved by a scroll.
    public var remembered: [ColumnID: PaneID] = [:]
    /// A sync skipped its reveal (live resize drag); the next one reveals.
    public var revealDeferred = false

    public struct Gesture: Hashable, Sendable {
        /// Unbanded offset accumulated from the deltas.
        public var raw: CGFloat
        public var samples: [Sample] = []
    }

    public struct Sample: Hashable, Sendable {
        public var time: TimeInterval
        public var delta: CGFloat
    }

    public struct RestorePoint: Hashable, Sendable {
        /// The column focused before the new one opened.
        public var column: ColumnID
        /// The column that opened right of it.
        public var opened: ColumnID
        /// Target offset then, relative to `column`'s leading edge.
        public var relativeOffset: CGFloat
    }

    public init() {}

    public var isGestureActive: Bool { gesture != nil }
}

/// One input to the column scroll reducer.
public nonisolated enum ColumnScrollEvent: Hashable, Sendable {
    /// A model snapshot: layout, geometry (viewport) or focus changed.
    /// `source` says what moved the focus when it changed.
    /// `reveals: false` (a divider or column-edge drag in progress) only
    /// anchors the camera; the reveal runs at the next sync that allows it.
    case sync(ColumnStrip, focused: PaneID?, source: ColumnFocusSource, animated: Bool, reveals: Bool = true)
    /// Center the column holding the pane once.
    case center(PaneID, animated: Bool)
    case gestureBegan
    case gestureChanged(deltaX: CGFloat, time: TimeInterval)
    case gestureEnded(time: TimeInterval, animated: Bool)
    /// One discrete mouse-wheel notch, +1 forward (offset increases).
    case wheel(direction: Int, animated: Bool)
    /// Scroll to an offset chosen by the strip scrollbar (a track click's
    /// page target); focus follows like a wheel notch.
    case page(to: CGFloat, animated: Bool)
}

/// What the view does after a reduce.
public nonisolated struct ColumnScrollEffects: Hashable, Sendable {
    /// The spring moves: run the display link.
    public var needsFrames = false
    /// The scroll moved focus to this pane (gesture end, wheel notch).
    public var focus: PaneID?
    /// Report the settled leading column when the spring rests.
    public var reportOnSettle = false
}
