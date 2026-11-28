public import AppKit
public import CmuxNextSettings
import CmuxNextWakeups

/// `cmux.page.visibleSlice`: the part of a drawn surface that is on screen, host to page, for a web-hosted list to
/// draw only its rows near it (Leo 2026-11-18, ask-1105ee4cc6: "we draw the visible area, right?"). A page subscribes
/// with `{surface}` and hears `{surface, revision, top, height}` in whole CSS px from the top of that surface (height
/// 0: scrolled out), the latest at once, then each change. `revision` is the surface's own content revision the slice
/// was measured against; the page drops one older than what it drew.
///
/// One per page (its route, ``route``): the host names each surface it draws ("sidebar-chats:earlier", a panel's
/// mount id) and pushes slices for it, usually through a ``PageVisibleSliceTracker``.
@MainActor
public final class PageVisibleSlices: PageProvider {
    public static let stream = "cmux.page.visibleSlice"

    /// One surface's visible part, in whole CSS px.
    public struct Slice: Equatable, Sendable {
        public var surface: String
        public var revision: Int
        public var top: Int
        public var height: Int

        public init(surface: String, revision: Int, top: Int, height: Int) {
            (self.surface, self.revision, self.top, self.height) = (surface, revision, top, height)
        }

        public var event: JSONValue {
            .object(["surface": .string(surface), "revision": .number(Double(revision)), "top": .number(Double(top)),
                     "height": .number(Double(height))])
        }
    }

    private var latest: [String: Slice] = [:]
    private var listeners: [String: [UUID: @MainActor (JSONValue) -> Void]] = [:]

    public init() {}

    /// The route a page that hears slices adds (its descriptor lists ``stream`` in `nativeOps`).
    public var route: PageRoute { PageRoute(prefix: Self.stream, provider: self) }

    /// The last slice sent for `surface`.
    public func slice(_ surface: String) -> Slice? { latest[surface] }

    /// Sends `slice` to its surface's subscribers unless it is the last one sent; returns whether it did.
    @discardableResult
    public func push(_ slice: Slice) -> Bool {
        guard latest[slice.surface] != slice else { return false }
        latest[slice.surface] = slice
        for listener in (listeners[slice.surface] ?? [:]).values { listener(slice.event) }
        return true
    }

    /// `surface` is gone (a panel unmounted): its last slice is dropped, so a new surface of that name starts afresh.
    public func forget(_ surface: String) {
        latest[surface] = nil
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        throw PageError.unknownOp(op)
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                          onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.stream else { throw PageError.unknownOp(stream) }
        guard let surface = filter["surface"]?.stringValue, !surface.isEmpty else { throw PageError.invalidParams("surface is required") }
        let id = UUID()
        listeners[surface, default: [:]][id] = onEvent
        if let slice = latest[surface] { onEvent(slice.event) }
        return PageSubscription { [weak self] in self?.listeners[surface]?[id] = nil }
    }

    public func pageDidClose() {
        listeners.removeAll()
    }
}

/// Measures one surface a view draws and pushes its slice to ``PageVisibleSlices``, at most once a display frame
/// (``needsSlice()``: the latest wins) and never when it did not change. `measure` answers the surface's visible rect
/// from its top (empty: off screen) and its height, or nil while no view draws it (nothing is sent: the page draws
/// whole); `revision` its content revision; `zoom` the page zoom (points to CSS px); `view` the view whose window
/// paces the frames.
@MainActor
public final class PageVisibleSliceTracker {
    public typealias Measure = @MainActor () -> (visible: CGRect, height: CGFloat)?
    public let surface: String
    private let slices: PageVisibleSlices
    private let measure: Measure
    private let revision: @MainActor () -> Int
    private let zoom: @MainActor () -> Double
    /// Runs for each slice sent (a list's work meter).
    public var onSend: (@MainActor (PageVisibleSlices.Slice) -> Void)?
    private var frame: FrameClient?

    public init(surface: String, slices: PageVisibleSlices, view: @escaping @MainActor () -> NSView?, measure: @escaping Measure,
                revision: @escaping @MainActor () -> Int, zoom: @escaping @MainActor () -> Double = { 1 }) {
        (self.surface, self.slices, self.measure, self.revision, self.zoom) = (surface, slices, measure, revision, zoom)
        // One tick sends the latest, then the client idles until something moves again.
        frame = FrameClient(owner: "Page.visibleSlice", scheduler: { view().map(FrameScheduler.forView) ?? .app }) { [weak self] _ in
            self?.sendNow()
            return false
        }
    }

    /// The surface `view` draws in its own bounds: its visible part, empty while hidden.
    public convenience init(surface: String, slices: PageVisibleSlices, view: NSView, revision: @escaping @MainActor () -> Int,
                            zoom: @escaping @MainActor () -> Double = { 1 }) {
        self.init(surface: surface, slices: slices, view: { [weak view] in view },
                  measure: { [weak view] in view.map(Self.visiblePart(of:)) }, revision: revision, zoom: zoom)
    }

    /// `view`'s part in sight, from its top (a view that is not flipped is turned over), and its height: the enclosing
    /// scroll view's visible document rect in `view`, clipped to its bounds (its own `visibleRect` only outside a scroll
    /// view; a view in no window or an unflushed clip reports its whole bounds there).
    public static func visiblePart(of view: NSView) -> (visible: CGRect, height: CGFloat) {
        let height = view.bounds.height
        guard !view.isHiddenOrHasHiddenAncestor else { return (.zero, height) }
        var visible: CGRect
        if let clip = view.enclosingScrollView?.contentView {
            let shown = view.convert(clip.bounds, from: clip).intersection(view.bounds)
            visible = shown.isNull || shown.height <= 0 ? .zero : shown
        } else {
            visible = view.visibleRect
        }
        if !view.isFlipped, !visible.isEmpty { visible.origin.y = view.bounds.maxY - visible.maxY }
        return (visible, height)
    }

    /// The slice now: from the visible rect's top, clamped to the surface, for its height; height 0 when none shows.
    /// Nil while nothing measures the surface.
    public var current: PageVisibleSlices.Slice? {
        guard let measured = measure() else { return nil }
        let (visible, height) = measured
        let zoom = max(zoom(), 0.01)
        let top = visible.isEmpty ? 0 : min(max(visible.minY, 0), height)
        let shown = visible.isEmpty ? 0 : visible.height
        return .init(surface: surface, revision: revision(), top: Int((Double(top) / zoom).rounded()),
                     height: Int((Double(shown) / zoom).rounded()))
    }

    /// Sends the slice on the next display frame.
    public func needsSlice() { frame?.activate() }

    /// Sends the slice now when it changed; returns whether it did.
    @discardableResult
    public func sendNow() -> Bool {
        guard let slice = current, slices.push(slice) else { return false }
        onSend?(slice)
        return true
    }

    /// The surface is gone: no more frames, and its last slice is dropped.
    public func stop() {
        frame?.deactivate()
        slices.forget(surface)
    }
}
