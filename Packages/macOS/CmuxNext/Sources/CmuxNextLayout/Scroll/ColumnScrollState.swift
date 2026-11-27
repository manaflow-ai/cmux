internal import CCmuxLayoutReducerFFI
public import CoreGraphics
public import CmuxNextDesign
public import Foundation

/// Scroll state of one strip: the spring the view presents, which the view steps each display frame, and the
/// column scroll rules (plans/cmux-next/column-scroll.md) that move it, held by cmux-layout-reducer behind a handle
/// (`cmux_scroll_*`; rules and tests in `cmux-layout-reducer/src/scroll`). Swift maps the strip and the event in and the
/// effects out; the spring stays here and goes in and out of every call. A class, so the handle is not copied.
public nonisolated final class ColumnScrollState {
    /// `value` is presented, `target` is where it settles. Offsets are the
    /// content-space x of the viewport's leading edge.
    public var spring = SpringValue(0)
    public var mode: CenterFocusedColumn = .never {
        didSet { if mode != oldValue { cmux_scroll_set_mode(handle, Self.code(mode)) } }
    }
    /// A keyboard resize press that trades width between two columns (`PaneResize.press`): the next sync keeps this
    /// column where it shows and reveals nothing, so only the divider the press moves moves. That sync clears it.
    public var keptColumn: ColumnID?
    private let handle: OpaquePointer

    public init() {
        guard let handle = cmux_scroll_new(0) else { preconditionFailure("cmux_scroll_new") }
        self.handle = handle
    }

    deinit { cmux_scroll_free(handle) }

    public var isGestureActive: Bool { cmux_scroll_gesture_active(handle) != 0 }

    /// The unbanded offset of a live trackpad gesture.
    public var gestureRaw: CGFloat? {
        let status = cmux_scroll_status(handle)
        return status.gesture_active != 0 ? CGFloat(status.gesture_raw) : nil
    }

    /// The pane the reducer follows, which a scroll that moves focus updates before the model echoes it.
    public var focusedPane: PaneID? {
        let status = cmux_scroll_status(handle)
        guard status.has_focused_pane != 0, let base = status.focused_pane else { return nil }
        return PaneID(String(decoding: UnsafeBufferPointer(start: base, count: status.focused_pane_len), as: UTF8.self))
    }

    /// The part of an anchor's shift `delta` a camera whose target is `target` can take in a strip with `maxOffset` of
    /// room: all of it while the shifted target stays in the strip, up to the strip's end otherwise, and none that would
    /// take a target already outside it further out (never a shift the other way).
    static func anchorShift(_ delta: CGFloat, target: CGFloat, maxOffset: CGFloat) -> CGFloat {
        delta > 0 ? min(delta, max(0, maxOffset - target)) : max(delta, min(0, -target))
    }

    @discardableResult
    public func reduce(_ event: ColumnScrollEvent) -> ColumnScrollEffects {
        var spring = CmuxScrollSpring(value: Double(self.spring.value), velocity: Double(self.spring.velocity),
                                      target: Double(self.spring.target))
        let handle = handle
        let raw: CmuxScrollEffects
        switch event {
        case let .sync(strip, focused, source, animated, reveals, anchor):
            let kept = keptColumn
            keptColumn = nil
            raw = Self.sync(handle, &spring, strip, focused: focused, source: source, animated: animated, reveals: reveals,
                            anchor: anchor ?? kept, keepsView: kept != nil)
        case let .center(pane, animated):
            raw = Array(pane.rawValue.utf8).withUnsafeBufferPointer { cmux_scroll_center(handle, &spring, $0.baseAddress, $0.count, animated ? 1 : 0) }
        case let .reveal(pane, animated):
            raw = Array(pane.rawValue.utf8).withUnsafeBufferPointer { cmux_scroll_reveal(handle, &spring, $0.baseAddress, $0.count, animated ? 1 : 0) }
        case .gestureBegan:
            raw = cmux_scroll_gesture_began(handle, &spring)
        case let .gestureChanged(deltaX, time):
            raw = cmux_scroll_gesture_changed(handle, &spring, Double(deltaX), time)
        case let .gestureEnded(time, animated):
            raw = cmux_scroll_gesture_ended(handle, &spring, time, animated ? 1 : 0)
        case let .page(offset, animated):
            raw = cmux_scroll_page(handle, &spring, Double(offset), animated ? 1 : 0)
        case let .wheel(direction, animated):
            raw = cmux_scroll_wheel(handle, &spring, Int32(direction), animated ? 1 : 0)
        }
        guard raw.ok != 0 else { return ColumnScrollEffects() }
        self.spring.value = CGFloat(spring.value)
        self.spring.velocity = CGFloat(spring.velocity)
        self.spring.target = CGFloat(spring.target)
        var effects = ColumnScrollEffects(needsFrames: raw.needs_frames != 0, reportOnSettle: raw.report_on_settle != 0, snapped: raw.snapped != 0)
        if raw.has_focus != 0, let base = raw.focus {
            effects.focus = PaneID(String(decoding: UnsafeBufferPointer(start: base, count: raw.focus_len), as: UTF8.self))
        }
        return effects
    }

    private static func code(_ mode: CenterFocusedColumn) -> UInt8 {
        switch mode {
        case .never: 0
        case .always: 1
        case .onOverflow: 2
        }
    }

    /// The strip as the request the reducer reads: ids as ranges into one byte buffer, panes in layout order then the
    /// panes that only have a frame.
    private static func sync(_ handle: OpaquePointer, _ spring: inout CmuxScrollSpring, _ strip: ColumnStrip, focused: PaneID?,
                             source: ColumnFocusSource, animated: Bool, reveals: Bool, anchor: ColumnID?, keepsView: Bool) -> CmuxScrollEffects {
        var bytes: [UInt8] = []
        func range(_ text: String?) -> CmuxScrollStr {
            guard let text else { return CmuxScrollStr(offset: UInt32.max, len: 0) }
            let start = bytes.count
            bytes.append(contentsOf: text.utf8)
            return CmuxScrollStr(offset: UInt32(start), len: UInt32(bytes.count - start))
        }
        func rect(_ frame: CGRect) -> CmuxScrollRect {
            CmuxScrollRect(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height))
        }
        var columns: [CmuxScrollColumn] = []
        var panes: [CmuxScrollPane] = []
        columns.reserveCapacity(strip.columns.count)
        for column in strip.columns {
            let start = panes.count
            let listed = Set(column.panes)
            for pane in column.panes + column.paneFrames.keys.filter({ !listed.contains($0) }).sorted() {
                let frame = column.paneFrames[pane]
                panes.append(CmuxScrollPane(id: range(pane.rawValue), frame: frame.map(rect) ?? CmuxScrollRect(x: 0, y: 0, width: 0, height: 0),
                                            has_frame: frame == nil ? 0 : 1, listed: listed.contains(pane) ? 1 : 0,
                                            reserved: (0, 0, 0, 0, 0, 0)))
            }
            columns.append(CmuxScrollColumn(id: range(column.id.rawValue), frame: rect(column.frame), pane_start: UInt32(start),
                                            pane_count: UInt32(panes.count - start)))
        }
        let sync = CmuxScrollSync(focused: range(focused?.rawValue), anchor: range(anchor?.rawValue), source: code(source),
                                  animated: animated ? 1 : 0, reveals: reveals ? 1 : 0, keeps_view: keepsView ? 1 : 0,
                                  reserved: (0, 0, 0, 0))
        return bytes.withUnsafeBufferPointer { bytes in
            columns.withUnsafeBufferPointer { columns in
                panes.withUnsafeBufferPointer { panes in
                    var request = CmuxScrollStrip(
                        bytes: bytes.baseAddress, columns: columns.baseAddress, panes: panes.baseAddress,
                        bytes_len: UInt32(bytes.count), column_count: UInt32(columns.count), pane_count: UInt32(panes.count),
                        axis: 0, reserved: (0, 0, 0), viewport_width: Double(strip.viewportWidth), content_width: Double(strip.contentWidth),
                        gap: Double(strip.gap), leading_cover: Double(strip.leadingCover), trailing_cover: Double(strip.trailingCover), origin: 0)
                    var sync = sync
                    return cmux_scroll_sync(handle, &spring, &request, &sync)
                }
            }
        }
    }

    private static func code(_ source: ColumnFocusSource) -> UInt8 {
        switch source {
        case .keyboard: 0
        case .pointer: 1
        case .programmatic: 2
        case .scroll: 3
        }
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
