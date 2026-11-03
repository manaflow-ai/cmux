public import CoreGraphics
public import CmuxNextDesign
public import Foundation

/// Scroll state of one scrolling strip (a columns screen, a column's rows or a
/// scroll area): the spring the view presents, and the column scroll reducer
/// that moves it. The reducer and its state (the strip, the focus it follows,
/// a live trackpad gesture, the restore point) are Rust's: cmux-layout-reducer
/// `scroll` through the app FFI's `cmux_scroll_*`, one handle per value, copied
/// on write. The view steps the spring each display frame; ``reduce(_:)`` sends
/// one event with it. plans/cmux-next/column-scroll.md.
public nonisolated struct ColumnScrollState {
    /// `value` is presented, `target` is where it settles. Offsets are the
    /// content-space x of the viewport's leading edge.
    public var spring = SpringValue(0)
    /// `layout.centerFocusedColumn`; read at each event.
    public var mode: CenterFocusedColumn = .never
    private var handle: ColumnScrollHandle

    /// A live trackpad gesture.
    public struct Gesture: Hashable, Sendable {
        /// Unbanded offset accumulated from the deltas.
        public var raw: CGFloat
    }

    /// The state of a columns screen.
    public init() {
        self.init(kind: .columns)
    }

    init(kind: ColumnScrollHandle.Kind) {
        handle = ColumnScrollHandle(kind: kind)
    }

    /// A trackpad gesture is in progress.
    public var isGestureActive: Bool { handle.isGestureActive }

    /// As a new state: no strip ever synced, no gesture, the spring at rest at 0 and
    /// centering `never`.
    public var isPristine: Bool {
        let status = handle.status
        return status.has_strip == 0 && status.gesture_active == 0 && spring == SpringValue(0) && mode == .never
    }

    /// The live trackpad gesture, nil without one.
    public var gesture: Gesture? {
        let status = handle.status
        return status.gesture_active != 0 ? Gesture(raw: CGFloat(status.gesture_raw)) : nil
    }

    /// The pane the reducer follows: the last synced focus, or the one a
    /// scroll moved focus to.
    public var focusedPane: PaneID? { handle.focusedPane }

    /// Applies one event; the spring and the reducer state change together.
    @discardableResult
    public mutating func reduce(_ event: ColumnScrollEvent) -> ColumnScrollEffects {
        if !isKnownUniquelyReferenced(&handle) { handle = handle.copy() }
        return handle.reduce(event, spring: &spring, mode: mode)
    }
}

/// One input to the column scroll reducer.
public nonisolated enum ColumnScrollEvent: Hashable, Sendable {
    /// A model snapshot: layout, geometry (viewport) or focus changed.
    /// `source` says what moved the focus when it changed.
    /// `reveals: false` (a divider or column-edge drag in progress) only
    /// anchors the camera; the reveal runs at the next sync that allows it.
    /// `anchor` is the column the camera keeps in place instead of the
    /// focused one: the column under a resize drag, whose leading edge must
    /// stay put so its edge follows the pointer (cx-ww20).
    case sync(ColumnStrip, focused: PaneID?, source: ColumnFocusSource, animated: Bool, reveals: Bool = true, anchor: ColumnID? = nil)
    /// Center the column holding the pane once.
    case center(PaneID, animated: Bool)
    /// Scroll the column holding the pane into view once, the least that shows it, without
    /// focusing it: a tab opened beside a chat that keeps focus (cx-27j7).
    case reveal(PaneID, animated: Bool)
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
    /// The offset jumped to a new target without frames (animation off or
    /// Reduce Motion), where a spring would have scrolled.
    public var snapped = false
}
