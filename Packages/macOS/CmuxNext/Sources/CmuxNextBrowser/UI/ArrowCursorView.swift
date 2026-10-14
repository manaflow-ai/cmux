public import AppKit

/// A toolbar row that shows the arrow over its whole frame and the I-beam
/// over the omnibar's text area (`OmnibarPointer`).
///
/// Cursor rects work only in the key window. A Chromium page is a child
/// window that takes the key while the page has the keyboard
/// (`WindowKeyFamily`), so the toolbar's rects did nothing and the arrow
/// stayed over the omnibar until a click made the parent key (Lawrence
/// 2026-10-13). The row also sets the cursor itself on every pointer move
/// over it, with a tracking area that works in any window state, and again
/// after the app handled a move while a child window has the key
/// (`pointerDidMove`). The rects stay for the key window; subviews with
/// their own rects (the editing omnibar text) take precedence inside it.
public class ArrowCursorView: NSView {
    private var cursorArea: NSTrackingArea?
    /// Owns the row's cursor tracking area, so the area's events end there
    /// and never travel up the responder chain (a tracking area keeps its
    /// owner unretained).
    private let cursorTracker = RowCursorTracker()
    /// The cursor the row last set on a pointer move (`debug.omnibar`).
    private(set) var trackedCursor: OmnibarPointer.Cursor?

    public override func resetCursorRects() {
        let arrow = OmnibarPointer.cursor(.toolbar).cursor
        guard Self.experiment("r"), let text = omnibarTextArea() else { return addCursorRect(bounds, cursor: arrow) }
        // The arrow everywhere but over the omnibar's text area (its own I-beam rect).
        for strip in [NSRect(x: bounds.minX, y: bounds.minY, width: text.minX - bounds.minX, height: bounds.height),
                      NSRect(x: text.maxX, y: bounds.minY, width: bounds.maxX - text.maxX, height: bounds.height),
                      NSRect(x: text.minX, y: bounds.minY, width: text.width, height: text.minY - bounds.minY),
                      NSRect(x: text.minX, y: text.maxY, width: text.width, height: bounds.maxY - text.maxY)]
            where strip.width > 0 && strip.height > 0 {
            addCursorRect(strip, cursor: arrow)
        }
    }

    /// The first omnibar's text area in the row's coordinates (cursor rects only).
    private func omnibarTextArea() -> NSRect? {
        var stack = subviews
        while let view = stack.popLast() {
            if let bar = view as? AddressBarView { return bar.convert(bar.textArea, to: self) }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // `.inVisibleRect` follows the view's visible rect: one area is enough. No
        // `.cursorUpdate`: AppKit sends a cursor update to the view under the pointer, which
        // may answer with the arrow (an input-host run with `.cursorUpdate` showed the arrow
        // past the end of the text in a window that was not key).
        guard cursorArea == nil else { return }
        #if DEBUG
        CursorTrace.install()
        #endif
        cursorTracker.row = self
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect]
        if Self.experiment("u") { options.insert(.cursorUpdate) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: cursorTracker)
        addTrackingArea(area)
        cursorArea = area
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.rows.removeAll { $0.row == nil || $0.row === self }
        if window != nil { Self.rows.append(WeakRow(row: self)) }
        if window != nil, Self.experiment("c") { Self.installCursorKeeper() }
    }

    // MARK: Experiment c: the row's cursor after AppKit's display cycle

    nonisolated(unsafe) private static var cursorKeeper: CFRunLoopObserver?

    /// After each run loop pass (after AppKit's display cycle, which sets the arrow for a key
    /// child window when its tracking areas change and the pointer is outside it), the row under
    /// a still pointer sets its cursor again when another one shows.
    private static func installCursorKeeper() {
        guard cursorKeeper == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { ArrowCursorView.keepCursor() }
        }
        cursorKeeper = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func keepCursor() {
        guard let key = NSApp.keyWindow, key.parent != nil else { return }
        let location = NSEvent.mouseLocation
        for entry in rows {
            guard let row = entry.row, let window = row.window, window !== key, window.isVisible else { continue }
            let point = window.convertPoint(fromScreen: location)
            guard row.visibleRect.contains(row.convert(point, from: nil)), !row.isHiddenOrHasHiddenAncestor else { continue }
            let cursor = OmnibarPointer.cursor(atWindowPoint: point, in: row)
            guard NSCursor.current !== cursor.cursor else { return }
            guard NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0) == window.windowNumber else { return }
            #if DEBUG
            CursorTrace.write("keeper sets \(cursor.rawValue) (was \(NSCursor.current === NSCursor.arrow ? "arrow" : "other"))")
            #endif
            row.trackedCursor = cursor
            cursor.cursor.set()
            return
        }
    }

    fileprivate func setCursor(at point: NSPoint) {
        let cursor = OmnibarPointer.cursor(atWindowPoint: point, in: self)
        trackedCursor = cursor
        cursor.cursor.set()
    }

    // MARK: After a move, while a child window has the key

    private struct WeakRow { weak var row: ArrowCursorView? }
    /// Rows in a window, so a move finds the row under the pointer without a view search.
    private static var rows: [WeakRow] = []

    /// Call after the app handled a pointer move (`NSApplication.sendEvent`).
    /// While a child window (a Chromium page) has the key, the key window's
    /// own handling of a move may set the arrow after the row's tracking
    /// event: the row under the pointer in a window that is not key sets its
    /// cursor again, last. Reads no event. With a top-level key window it
    /// returns after one property read; otherwise it compares the pointer
    /// with each row's visible rect and asks the window server for the window
    /// under the pointer only when a row contains it. No allocation.
    public static func pointerDidMove() {
        guard let key = NSApp.keyWindow, key.parent != nil else { return }
        #if DEBUG
        let start = DispatchTime.now().uptimeNanoseconds
        defer { MoveHookStats.record(nanoseconds: DispatchTime.now().uptimeNanoseconds - start) }
        #endif
        let location = NSEvent.mouseLocation
        for entry in rows {
            guard let row = entry.row, let window = row.window, window !== key, window.isVisible else { continue }
            let point = window.convertPoint(fromScreen: location)
            guard row.visibleRect.contains(row.convert(point, from: nil)), !row.isHiddenOrHasHiddenAncestor else { continue }
            guard NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0) == window.windowNumber else { return }
            row.setCursor(at: point)
            return
        }
    }
}

#if DEBUG
/// What `pointerDidMove` costs past its first check (`debug.omnibar`'s `move_hook`).
enum MoveHookStats {
    @MainActor private(set) static var calls = 0
    @MainActor private(set) static var totalNanoseconds: UInt64 = 0
    @MainActor static func record(nanoseconds: UInt64) {
        calls += 1
        totalNanoseconds += nanoseconds
    }
}
#endif

/// The owner of `ArrowCursorView`'s cursor tracking area: an enter or a
/// move sets the row's cursor; nothing goes further. It reads
/// only `locationInWindow` of an enter or a move (a mouse event), never
/// `trackingArea` (AppKit raises on it for a move).
private final class RowCursorTracker: NSResponder {
    weak var row: ArrowCursorView?

    /// Experiment d: the key child page window whose cursor rects are off while the pointer is over the row.
    private weak var quietedWindow: NSWindow?

    override func mouseEntered(with event: NSEvent) {
        row?.setCursor(at: event.locationInWindow)
        if ArrowCursorView.experiment("d"), let key = NSApp.keyWindow, key.parent != nil, key.parent === row?.window {
            key.disableCursorRects()
            quietedWindow = key
        }
    }
    override func mouseMoved(with event: NSEvent) { row?.setCursor(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {
        quietedWindow?.enableCursorRects()
        quietedWindow = nil
    }
    /// Experiment `u`: the row answers AppKit's cursor update with its own cursor at the pointer
    /// (read from the window, not from the event).
    override func cursorUpdate(with event: NSEvent) {
        guard let row, let window = row.window else { return }
        row.setCursor(at: window.mouseLocationOutsideOfEventStream)
    }
}
