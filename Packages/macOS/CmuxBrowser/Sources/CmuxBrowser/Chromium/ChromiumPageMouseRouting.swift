public import AppKit

/// Divider grab bands next to Chromium pages.
///
/// A split divider's grab band is wider than its line and reaches into the
/// panes beside it. A Chromium page is a child window above the cmux window,
/// so it would take the mouse in the part of the band over it: no resize
/// cursor and no drag there. While the pointer is in such a part, the page
/// leaves a hole over it, so the divider under it gets the cursor and the
/// press as next to a WebKit page; at rest the page draws edge to edge.
///
/// Reference: cmux Next `CmuxNextLayout/Views/DividerMouseCatchers.swift`
/// (Next covers the bands with click-catching panels instead).
public enum ChromiumDividerBands {
    /// A divider's grab area in window coordinates.
    public struct Divider: Equatable, Sendable {
        public var hitRect: CGRect
        /// A vertical divider (side-by-side panes) resizes columns.
        public var isVertical: Bool

        public init(hitRect: CGRect, isVertical: Bool) {
            self.hitRect = hitRect
            self.isVertical = isVertical
        }
    }

    /// The part of a divider's grab area over a page, in window coordinates.
    public struct Band: Equatable, Sendable {
        public var rect: CGRect
        public var isVertical: Bool

        public init(rect: CGRect, isVertical: Bool) {
            self.rect = rect
            self.isVertical = isVertical
        }
    }

    /// The band under `point`: the part over a page of a divider's grab area
    /// that holds the point, nil when the point is in none (or not over a page).
    /// - Parameters:
    ///   - point: The pointer in window coordinates.
    ///   - pages: The shown pages' frames in window coordinates.
    ///   - dividers: The dividers next to the pages.
    public static func band(at point: CGPoint, pages: [CGRect], dividers: [Divider]) -> Band? {
        for divider in dividers where divider.hitRect.contains(point) {
            for page in pages {
                let part = divider.hitRect.intersection(page)
                if !part.isNull, !part.isEmpty, part.contains(point) {
                    return Band(rect: part, isVertical: divider.isVertical)
                }
            }
        }
        return nil
    }
}

/// Lets a press that started in a cmux window reach that window's drop
/// targets over its Chromium pages.
///
/// A tab dragged from a pane's tab bar over a Chromium pane would be offered
/// to the page window above the pane, which knows nothing of cmux tabs, so the
/// pane showed no split drop zone and took no drop. While a press that began
/// in the cmux window is held (a tab drag, a divider drag, a selection), its
/// page windows ignore the mouse, so the drag reaches the pane's drop targets
/// as over a WebKit pane. Pages need no mouse during such a press: AppKit
/// keeps its events with the window the press began in. They take the mouse
/// again on the window's first update after every button is up.
@MainActor
public final class ChromiumPagePressGate {
    private let pressedMouseButtons: @MainActor () -> Int
    private weak var window: NSWindow?
    private var ignoring: [WeakWindow] = []
    private var updateObserver: (any NSObjectProtocol)?

    /// - Parameter pressedMouseButtons: The buttons held now (`NSEvent.pressedMouseButtons`).
    public init(pressedMouseButtons: @escaping @MainActor () -> Int = { NSEvent.pressedMouseButtons }) {
        self.pressedMouseButtons = pressedMouseButtons
    }

    deinit {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        }
    }

    /// Whether a press is being held over the pages of a window.
    public var isHolding: Bool { !ignoring.isEmpty }

    /// A press began in `window` itself (not in one of its page windows):
    /// its shown page windows ignore the mouse until every button is up.
    public func pressBegan(in window: NSWindow) {
        // A hold for another window (or one that closed meanwhile) ends first,
        // so the observer always follows the window holding now.
        if updateObserver != nil || isHolding, self.window !== window { release() }
        let pages = (window.childWindows ?? []).filter { $0.isChromiumPageWindow && !$0.ignoresMouseEvents }
        guard !pages.isEmpty else { return }
        self.window = window
        for page in pages {
            page.ignoresMouseEvents = true
            ignoring.append(WeakWindow(window: page))
        }
        guard updateObserver == nil else { return }
        updateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowDidUpdate() }
        }
    }

    /// The window processed an event: once no button is held, the pages take the mouse again.
    public func windowDidUpdate() {
        guard isHolding, pressedMouseButtons() == 0 else { return }
        release()
    }

    /// Gives every page this gate changed the mouse back.
    public func release() {
        for page in ignoring { page.window?.ignoresMouseEvents = false }
        ignoring.removeAll()
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        updateObserver = nil
        window = nil
    }

    private struct WeakWindow {
        weak var window: NSWindow?
    }
}
