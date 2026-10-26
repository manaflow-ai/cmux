import AppKit

/// Where a hosted page view's drags go: the shim's DragTarget calls in the app (`CEFPaneDragWire`),
/// a recorder in tests.
protocol ChromiumHostDragWire: AnyObject {
    /// The browser the page view shows now; nil refuses the drag.
    var dragBrowser: Int32? { get }
    /// Sends one call, one-way: the page answers an enter or over with DRAG_OPERATION.
    func send(_ event: ChromiumHostDragEvent, browser: Int32)
}

/// A hosted page's drag destination (task 050 of plans/cmux-next/chrome-parity/p01-process.md).
///
/// The host's page window is detached (fork API 30) and never ordered in, so the WindowServer gives
/// it no drags: cmux's page view takes them and sends DragTarget enter, over, leave and drop to the
/// page's browser, as Chrome's `WebDragDest` does for `RenderWidgetHostViewCocoa`
/// (content/browser/web_contents/web_drag_dest_mac.mm). The renderer answers each enter and over
/// later (DRAG_OPERATION, fork API 31's `cmux_browser_drag_target_watch`); AppKit gets the last
/// answer at once, as `WebDragDest` returns its `_currentOperation`. Until the first answer the
/// destination offers copy, so the drop is not refused before the page has seen the drag.
/// What a page view's drag destination sent and heard: a drop that went through Chromium's
/// DragTarget calls counts one enter and one drop, and the renderer's DRAG_OPERATION replies
/// count as answers. chromium-host-bench.py's dragin row reads them to tell those drops from the
/// DevTools relay's.
public struct ChromiumHostDragCounts: Equatable, Sendable {
    /// The page view takes drags (feature `chromiumHostDragIn` in host mode).
    public var takesDrags = false
    public var enters = 0
    public var drops = 0
    public var answers = 0
}

final class ChromiumHostDragDestination {
    /// The fork API whose DragTarget calls reach a detached page and report their answers (task 172).
    static let forkAPI: Int32 = 31

    /// Where drags go; nil takes none.
    var wire: (any ChromiumHostDragWire)?
    /// The browser of the drag in progress, nil while none.
    private(set) var browser: Int32?
    /// What AppKit gets back: the renderer's last choice for this drag.
    private(set) var operation: NSDragOperation = []
    /// The DragTarget enters and drops sent and the renderer's answers taken (`debug.cef`'s `page_drag`).
    private(set) var counts = ChromiumHostDragCounts()

    /// The `cef_drag_operations_mask_t` bits CEF defines (copy, link, generic, private, move,
    /// delete); NSDragOperation has the same values.
    private static let operationBits: Int32 = 0x3f

    func entered(_ data: ChromiumHostDropData, at point: ChromiumHostDragPoint, allowed: NSDragOperation,
                 modifiers: Int32) -> NSDragOperation {
        // A drag that never exited (its view left the window) ends before the next one starts.
        exited()
        guard let wire, let target = wire.dragBrowser, !data.isEmpty else { return [] }
        browser = target
        operation = .copy
        wire.send(.enter(data, point, allowed: Self.mask(allowed), modifiers: modifiers), browser: target)
        counts.enters += 1
        return operation
    }

    /// A move, or AppKit's periodic update while the pointer rests: each is a DragTarget over, which
    /// Blink turns into the page's dragover events (they repeat while the pointer rests, as the HTML
    /// drag model fires them).
    func updated(at point: ChromiumHostDragPoint, allowed: NSDragOperation, modifiers: Int32) -> NSDragOperation {
        guard let browser, let wire else { return [] }
        wire.send(.over(point, allowed: Self.mask(allowed), modifiers: modifiers), browser: browser)
        return operation
    }

    /// The drag left the page view, or its session ended with no drop here.
    func exited() {
        guard let browser else { return }
        end()
        wire?.send(.leave, browser: browser)
    }

    /// AppKit drops only after an answer other than none; the renderer then runs the drop.
    func dropped(at point: ChromiumHostDragPoint, modifiers: Int32) -> Bool {
        guard let browser, let wire else { return false }
        end()
        wire.send(.drop(point, modifiers: modifiers), browser: browser)
        counts.drops += 1
        return true
    }

    /// DRAG_OPERATION: the renderer's answer to an enter or over of `answering`. An answer for
    /// another browser, or one after the drag ended, changes nothing. Whether the document handles
    /// the drop matters to the renderer alone, so it is not kept.
    func answered(browser answering: Int32, operation answer: Int64) {
        guard answering == browser else { return }
        counts.answers += 1
        operation = NSDragOperation(rawValue: UInt(truncatingIfNeeded: answer & Int64(Self.operationBits)))
    }

    private func end() {
        browser = nil
        operation = []
    }

    static func mask(_ operations: NSDragOperation) -> Int32 {
        Int32(truncatingIfNeeded: operations.rawValue) & operationBits
    }

    /// `cef_event_flags_t` of the held keys and buttons, as Chrome's `GetModifierFlags` reads them for
    /// a drag (web_drag_dest_mac.mm). `pressedButtons` is `NSEvent.pressedMouseButtons` (1 left,
    /// 2 right, 4 middle).
    static func modifiers(_ flags: NSEvent.ModifierFlags, pressedButtons: Int) -> Int32 {
        var bits: Int32 = 0
        if flags.contains(.capsLock) { bits |= 1 << 0 }
        if flags.contains(.shift) { bits |= 1 << 1 }
        if flags.contains(.control) { bits |= 1 << 2 }
        if flags.contains(.option) { bits |= 1 << 3 }
        if pressedButtons & 1 != 0 { bits |= 1 << 4 }
        if pressedButtons & 4 != 0 { bits |= 1 << 5 }
        if pressedButtons & 2 != 0 { bits |= 1 << 6 }
        if flags.contains(.command) { bits |= 1 << 7 }
        return bits
    }
}
