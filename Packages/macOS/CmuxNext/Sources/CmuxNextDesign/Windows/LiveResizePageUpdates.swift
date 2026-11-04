public import AppKit

/// A window's Chromium page update requests during its live resize, sent as one per applied drag (FRAME OWNER REFACTOR
/// S7; the window's overlay layer owns one). AppKit applies each drag of a live resize with a `setFrame` that lays the
/// window's tree out inside it: the requests of one applied drag (the layout's overlay sync, a page window the fork
/// moved, the window's didResize) reach the pages once, when that `setFrame` returns, with the final geometry. Each
/// request reaches every page of the window, and each page works its geometry, clip and occlusion out again. Through the
/// resize the window's divider catcher panels stay where they are: nothing clicks or hovers a divider while AppKit tracks
/// it.
@MainActor
public final class LiveResizePageUpdates {
    /// What the held update asks: `force` (every page re-applies, changed or not) when any request forced it;
    /// `geometryOnly` (no clip shape changed) only when every request was. Nil: nothing is held.
    public private(set) var held: (force: Bool, geometryOnly: Bool)?
    /// The resize's end runs now (``end(_:)``): the window no longer counts as resizing live.
    private var ending = false
    /// The window's live-resize drag input: whether it holds page updates (``LiveResizeDragInput/holdsPageUpdates``)
    /// and whether the held one waits for the commit (``LiveResizeDragInput/holdsUntilCommit``).
    private let input: @MainActor () -> LiveResizeDragInput?

    /// `input`: the window's live-resize drag input; with none, or one that holds nothing, every request goes at once.
    public init(input: @escaping @MainActor () -> LiveResizeDragInput?) {
        self.input = input
    }

    /// Whether `window` resizes live on the frame tick now (``Motion/isInLiveResize(_:)``), but not while its end runs.
    public func isActive(in window: NSWindow) -> Bool { !ending && Motion.isInLiveResize(window) && input()?.holdsPageUpdates == true }

    /// Holds a request when `window` resizes live: true when held (the caller sends nothing now).
    public func holds(force: Bool, geometryOnly: Bool, in window: NSWindow) -> Bool {
        guard isActive(in: window) else { return false }
        held = held.map { ($0.force || force, $0.geometryOnly && geometryOnly) } ?? (force, geometryOnly)
        return true
    }

    /// The held update, if any; nothing is held after it. Nil while the drag input holds it until the commit shows.
    public func take() -> (force: Bool, geometryOnly: Bool)? {
        guard input()?.holdsUntilCommit != true else { return nil }
        defer { held = nil }
        return held
    }

    /// Runs the resize's end: `body` gets whether a held update was forced (it joins the end's own update) and runs
    /// with the window no longer counting as resizing live, so the catcher panels move and the pages hear the end.
    public func end(_ body: (_ forced: Bool) -> Void) {
        let forced = take()?.force == true
        ending = true
        defer { ending = false }
        body(forced)
    }
}
