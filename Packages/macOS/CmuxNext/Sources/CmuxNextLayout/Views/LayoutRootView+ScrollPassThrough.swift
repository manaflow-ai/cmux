import AppKit
import CmuxNextDesign

/// Where an intercepted scroll comes from, and the scrolls that leave the layout's routing in O(1).
/// The layout's tap intercept hears every scroll of its window and of its page
/// windows; most of them are not the layout's, and those must cost no point conversion, pane hit
/// test or claim query before they go on.
extension LayoutRootView {
    /// True when `event` goes on untouched, decided without any point conversion, pane hit test or
    /// claim query. Chrome keeps such scrolls off the main thread's hit testing the same way: only a
    /// listed reason sends a scroll there (cc/input/main_thread_scrolling_reason.h).
    ///
    /// With no gesture of the layout's in progress (no lock, no coast to swallow), two kinds pass:
    ///
    /// - A gesture's changes and any momentum, from any window with any modifier: the gesture's first
    ///   event already decided it is not the layout's (`LayoutRootView+Scroll`).
    /// - Every event of a plain scroll from a page window, which the layout never takes. The gesture
    ///   bookkeeping stays what the full route keeps, so Command pressed after a page's touch still
    ///   leaves the gesture to the page. AppKit hit tests them in the page window, so no strip lands
    ///   for them (``landStripsWhereTheyShow()``). Focus follows mouse needs the pane under the
    ///   pointer, so with it on these take the full route.
    func passesWithoutRouting(_ event: NSEvent, from eventWindow: NSWindow?) -> Bool {
        switch scrollLock {
        case .idle, .passthrough: break
        case .undecided, .horizontal, .area, .vertical, .canvas, .canvasCoast, .canvasUndecided, .claimed: return false
        }
        guard !consumeMomentum else { return false }
        let phase = event.phase
        let decisive: NSEvent.Phase = [.mayBegin, .began, .ended, .cancelled]
        if !event.momentumPhase.isEmpty || (!phase.isEmpty && phase.isDisjoint(with: decisive)) { return true }
        guard isPlainPageScroll(event, from: eventWindow) else { return false }
        if phase.isEmpty { return true }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            ownerDecidedAtTouch = false
            scrollLock = .idle
        } else if phase.contains(.mayBegin) {
            // The page's touch decides its gesture; the began, end or cancel that follows clears it.
            ownerDecidedAtTouch = true
            scrollLock = .passthrough
        } else if ownerDecidedAtTouch {
            ownerDecidedAtTouch = false
        } else {
            scrollLock = .passthrough
        }
        return true
    }

    /// Whether `event` comes from one of this layout's page windows (a non-panel child of its window,
    /// as ``scrollOrigin(of:at:in:)`` counts one) as a scroll the layout never takes: no Command under
    /// `command`, any scroll under `none`, and focus follows mouse off. A window whose pages draw in its
    /// view tree (``PageSurface/views``) has no page window: its pages' scrolls are its own events.
    private func isPlainPageScroll(_ event: NSEvent, from eventWindow: NSWindow?) -> Bool {
        guard let window, let eventWindow, eventWindow !== window, eventWindow.parent === window,
              !(eventWindow is NSPanel), WindowOverlayHost.isPageWindow(eventWindow, on: PageSurface.of(window)) else { return false }
        let layoutModifier = model.scrollModifier == .command && event.modifierFlags.contains(.command)
        return !layoutModifier && !model.focusFollowsMouse
    }

    /// Scrolls this root's intercept sent through its full routing, with its pane hit tests and claim
    /// queries (`debug.layout_counters` `scroll_routes`, cumulative per root: read a delta).
    public var routedScrolls: UInt64 { context.routedScrolls }

    /// Scroll points this root's intercept converted from a child window into its own
    /// (`debug.layout_counters` `scroll_conversions`, cumulative per root: read a delta).
    public var scrollPointConversions: UInt64 { context.scrollPointConversions }

    /// ``scrollOrigin(of:at:in:)`` for this layout's window, counting each point it converts
    /// (``scrollPointConversions``).
    func scrollOrigin(of eventWindow: NSWindow?, at location: NSPoint) -> ScrollOrigin? {
        let origin = Self.scrollOrigin(of: eventWindow, at: location, in: window)
        if origin != nil, eventWindow !== window { context.scrollPointConversions &+= 1 }
        return origin
    }

    /// Where an intercepted scroll event came from, as the layout of one window routes it.
    struct ScrollOrigin: Equatable {
        /// The event's point in the layout's window.
        var locationInWindow: NSPoint
        /// The event came from a page window over a pane, not from the layout's window itself.
        var isPageWindow: Bool
    }

    /// Where a scroll event of `eventWindow` at `location` points in `window`, the layout's window:
    /// its own point when it is that window's. Two kinds of child window of `window` count too,
    /// their point converted:
    ///
    /// - The layout's own divider catcher panels (``DividerMousePanel``), which cover every divider
    ///   hit area while a Chromium page shows: layout input, as the same gap is with no page.
    /// - A Chromium page's own window (a non-panel child over its pane), flagged `isPageWindow`:
    ///   under `command` its Command + scroll moves the layout; under either modifier a gesture the
    ///   layout took keeps its events when a pan slides a page under the still pointer, and a
    ///   gesture that starts there ends the last one's lock.
    ///
    /// Other panels never count: overlays, and the remote browser's popups (`ContentChildPanel`),
    /// whose lists scroll themselves. Catcher panels and page windows are in-process machinery: a
    /// window whose pages draw in its view tree (``PageSurface/views``) has neither, so only its own
    /// events are the layout's. Nil: not this layout's.
    static func scrollOrigin(of eventWindow: NSWindow?, at location: NSPoint, in window: NSWindow?) -> ScrollOrigin? {
        guard let window, let eventWindow else { return nil }
        if eventWindow === window { return ScrollOrigin(locationInWindow: location, isPageWindow: false) }
        guard eventWindow.parent === window, PageSurface.of(window) == .childWindows else { return nil }
        let isCatcher = eventWindow is DividerMousePanel
        guard isCatcher || (!(eventWindow is NSPanel) && WindowOverlayHost.isPageWindow(eventWindow)) else { return nil }
        let point = window.convertPoint(fromScreen: eventWindow.convertPoint(toScreen: location))
        return ScrollOrigin(locationInWindow: point, isPageWindow: !isCatcher)
    }
}
