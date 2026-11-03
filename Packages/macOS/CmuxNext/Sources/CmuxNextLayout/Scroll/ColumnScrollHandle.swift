import CCmuxLayoutReducerFFI
import CmuxNextDesign
import CoreGraphics

/// The Rust column scroll reducer of one ``ColumnScrollState`` (cmux-layout-reducer
/// `scroll`, C ABI `cmux_scroll_*`): one handle, and the buffers a sync encodes
/// its strip into, kept across calls. A call on a uniquely held handle allocates
/// nothing in steady state; a copy of the owning value (copy on write) clones the
/// handle and its buffers, which the row and area callers in ScreenContentView do
/// at each sync, gesture end and wheel notch.
nonisolated final class ColumnScrollHandle {
    /// Which strip the handle reduces (the C ABI's kind).
    enum Kind: UInt8 {
        case columns = 0
        case rows = 1
        case area = 2
    }

    /// Nil only if Rust refused the kind (it never does for a `Kind`); every call then
    /// replies `ok == 0` and the state stays at rest.
    private let pointer: OpaquePointer?
    private let kind: Kind
    private var bytes: [UInt8] = []
    private var columns: [CmuxScrollColumn] = []
    private var panes: [CmuxScrollPane] = []

    init(kind: Kind) {
        self.kind = kind
        pointer = cmux_scroll_new(kind.rawValue)
    }

    private init(copying other: ColumnScrollHandle) {
        kind = other.kind
        pointer = cmux_scroll_clone(other.pointer) ?? cmux_scroll_new(other.kind.rawValue)
    }

    deinit {
        cmux_scroll_free(pointer)
    }

    /// An independent copy (copy on write of the owning value).
    func copy() -> ColumnScrollHandle {
        ColumnScrollHandle(copying: self)
    }

    var status: CmuxScrollStatus { cmux_scroll_status(pointer) }

    /// Read per frame for every row and area: no focus lookup.
    var isGestureActive: Bool { cmux_scroll_gesture_active(pointer) != 0 }

    var focusedPane: PaneID? {
        let status = status
        guard status.has_focused_pane != 0 else { return nil }
        return PaneID(Self.string(status.focused_pane, status.focused_pane_len))
    }

    // perf-hot: 0.05ms column-scroll-reduce
    func reduce(_ event: ColumnScrollEvent, spring: inout SpringValue, mode: CenterFocusedColumn) -> ColumnScrollEffects {
        cmux_scroll_set_mode(pointer, mode.code)
        var state = CmuxScrollSpring(value: Double(spring.value), velocity: Double(spring.velocity), target: Double(spring.target))
        let reply: CmuxScrollEffects = switch event {
        case let .sync(strip, focused, source, animated, reveals, anchor):
            sync(strip, focused: focused, source: source, animated: animated, reveals: reveals, anchor: anchor, spring: &state)
        case let .center(pane, animated):
            Array(pane.rawValue.utf8).withUnsafeBufferPointer { cmux_scroll_center(pointer, &state, $0.baseAddress, $0.count, animated.code) }
        case let .reveal(pane, animated):
            Array(pane.rawValue.utf8).withUnsafeBufferPointer { cmux_scroll_reveal(pointer, &state, $0.baseAddress, $0.count, animated.code) }
        case .gestureBegan:
            cmux_scroll_gesture_began(pointer, &state)
        case let .gestureChanged(deltaX, time):
            cmux_scroll_gesture_changed(pointer, &state, Double(deltaX), time)
        case let .gestureEnded(time, animated):
            cmux_scroll_gesture_ended(pointer, &state, time, animated.code)
        case let .wheel(direction, animated):
            cmux_scroll_wheel(pointer, &state, Int32(clamping: direction), animated.code)
        case let .page(offset, animated):
            cmux_scroll_page(pointer, &state, Double(offset), animated.code)
        }
        spring.value = CGFloat(state.value)
        spring.velocity = CGFloat(state.velocity)
        spring.target = CGFloat(state.target)
        guard reply.ok != 0 else { return ColumnScrollEffects() }
        var effects = ColumnScrollEffects()
        effects.needsFrames = reply.needs_frames != 0
        effects.reportOnSettle = reply.report_on_settle != 0
        effects.snapped = reply.snapped != 0
        if reply.has_focus != 0 { effects.focus = PaneID(Self.string(reply.focus, reply.focus_len)) }
        return effects
    }

    // perf-hot: 0.05ms column-scroll-reduce
    private func sync(_ strip: ColumnStrip, focused: PaneID?, source: ColumnFocusSource, animated: Bool, reveals: Bool,
                      anchor: ColumnID?, spring: inout CmuxScrollSpring) -> CmuxScrollEffects {
        bytes.removeAll(keepingCapacity: true)
        columns.removeAll(keepingCapacity: true)
        panes.removeAll(keepingCapacity: true)
        for column in strip.columns {
            let id = append(column.id.rawValue)
            let start = UInt32(panes.count)
            for pane in column.panes {
                panes.append(Self.pane(append(pane.rawValue), frame: column.paneFrames[pane], listed: true))
            }
            // A framed pane that is not listed still names the column (Swift's `index(ofPane:)`).
            for (pane, frame) in column.paneFrames where !column.panes.contains(pane) {
                panes.append(Self.pane(append(pane.rawValue), frame: frame, listed: false))
            }
            columns.append(CmuxScrollColumn(id: id, frame: Self.rect(column.frame), pane_start: start,
                                            pane_count: UInt32(panes.count) - start))
        }
        let focusedRange = focused.map { append($0.rawValue) } ?? Self.absent
        let anchorRange = anchor.map { append($0.rawValue) } ?? Self.absent
        var request = CmuxScrollSync(focused: focusedRange, anchor: anchorRange, source: source.code, animated: animated.code,
                                     reveals: reveals.code, reserved: (0, 0, 0, 0, 0))
        return bytes.withUnsafeBufferPointer { bytes in
            columns.withUnsafeBufferPointer { columns in
                panes.withUnsafeBufferPointer { panes in
                    var encoded = CmuxScrollStrip(
                        bytes: bytes.baseAddress, columns: columns.baseAddress, panes: panes.baseAddress,
                        bytes_len: UInt32(bytes.count), column_count: UInt32(columns.count), pane_count: UInt32(panes.count),
                        axis: strip.axis == .vertical ? 1 : 0, reserved: (0, 0, 0),
                        viewport_width: Double(strip.viewportWidth), content_width: Double(strip.contentWidth),
                        gap: Double(strip.gap), leading_cover: Double(strip.leadingCover),
                        trailing_cover: Double(strip.trailingCover), origin: Double(strip.origin))
                    return cmux_scroll_sync(pointer, &spring, &encoded, &request)
                }
            }
        }
    }

    /// An absent string (`CMUX_SCROLL_NONE`).
    private static let absent = CmuxScrollStr(offset: UInt32.max, len: 0)

    /// Appends `text` to the request bytes; its range.
    private func append(_ text: String) -> CmuxScrollStr {
        let offset = UInt32(bytes.count)
        bytes.append(contentsOf: text.utf8)
        return CmuxScrollStr(offset: offset, len: UInt32(bytes.count) - offset)
    }

    private static func pane(_ id: CmuxScrollStr, frame: CGRect?, listed: Bool) -> CmuxScrollPane {
        CmuxScrollPane(id: id, frame: frame.map(rect) ?? CmuxScrollRect(), has_frame: frame == nil ? 0 : 1,
                       listed: listed ? 1 : 0, reserved: (0, 0, 0, 0, 0, 0))
    }

    private static func rect(_ rect: CGRect) -> CmuxScrollRect {
        CmuxScrollRect(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.size.width), height: Double(rect.size.height))
    }

    private static func string(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> String {
        guard let bytes, count > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }
}

private nonisolated extension Bool {
    var code: UInt8 { self ? 1 : 0 }
}

private nonisolated extension ColumnFocusSource {
    var code: UInt8 {
        switch self {
        case .keyboard: 0
        case .pointer: 1
        case .programmatic: 2
        case .scroll: 3
        }
    }
}

private nonisolated extension CenterFocusedColumn {
    var code: UInt8 {
        switch self {
        case .never: 0
        case .always: 1
        case .onOverflow: 2
        }
    }
}
