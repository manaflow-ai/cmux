public import AppKit

// The kinds of InputEventTap subscription (plans/cmux-next/chrome-parity/p04-input.md section 3 (A)):
// when an observer runs, where an intercept sits among the others, what an intercept returns and which
// windows a subscription hears.
extension InputEventTap {
    /// When an observer runs in the event's dispatch. Its handler returns nothing: it cannot stop the
    /// event. The third phase, `.intercept(order:)`, is ``InterceptPhase``: its handler returns an
    /// ``InterceptResult``, so at a call site the phase picks the handler type and never the reverse.
    public enum Phase: Sendable, Equatable {
        /// Before the key router and any responder.
        case observe
        /// After AppKit dispatched the event (focus has moved to a clicked pane), also when an
        /// intercept consumed it. A key the key router consumed never gets here.
        case afterDispatch
    }

    /// The phase of an intercept: after the key router and before AppKit dispatches the event, where
    /// AppKit's local monitors ran. Its handler returns whether it consumed the event.
    public enum InterceptPhase: Sendable, Equatable {
        /// In `order` among the other intercepts (``InterceptOrder``'s table).
        case intercept(order: InterceptOrder)
    }

    /// The delivery stages of one event, in order: observers, intercepts, after-dispatch observers,
    /// and the end of its dispatch (``InputEventTap/observeDispatchEnd(_:_:)``).
    public enum Stage: Sendable, Equatable {
        case observe, intercept, afterDispatch, dispatchEnd
    }

    /// How an event's dispatch ended, for ``InputEventTap/observeDispatchEnd(_:_:)``.
    public enum DispatchOutcome: Sendable, Equatable {
        /// AppKit dispatched it to its window (`super.sendEvent`).
        case delivered
        /// cmux consumed it first (the key router, the find pill, the cross-window key guard or an
        /// intercept): no window got it.
        case consumed
    }

    /// Where an intercept runs among the others: lower first, equal orders in subscription order.
    /// Intercepts run where AppKit's local monitors ran: after the key router, before
    /// `NSApplication.sendEvent` dispatches the event. Every owner takes a named order from this table,
    /// so the order of two owners is read here, not found by trying.
    ///
    /// | Order | Owner |
    /// | --- | --- |
    /// | ``modal`` | a modal overlay's Escape and outside click (before any popup): `WindowOverlayHost`'s Escape |
    /// | ``popup`` | popups, menus and hover cards that close on Escape or an outside click: `NativePopupHost`'s Escape in its panel (keys only) and `HoverCardCoordinator`'s wheel scroll on the card (scrolls only): they share no class, so their mutual order does not matter |
    /// | ``dragSession`` | a tab, link, pane or screen drag in progress (Escape and mouse-up end it) |
    /// | ``layout`` | the layout's scroll, magnify and button routing |
    /// | ``standard`` | everything else, such as the sidebar's space paging (`SidebarSwipeFeed`), which passes every scroll but hears none an order above consumed |
    ///
    /// Owners that only watch (a tooltip put away by a click, a popup closed by a click outside it, a
    /// hover card ended by a key or a click, the overlay panel's mouse routing) are observers, not
    /// intercepts: they never stop an event, and an intercept that consumes one never hides it from them.
    public struct InterceptOrder: Comparable, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let modal = InterceptOrder(rawValue: 100)
        public static let popup = InterceptOrder(rawValue: 200)
        public static let dragSession = InterceptOrder(rawValue: 300)
        public static let layout = InterceptOrder(rawValue: 400)
        public static let standard = InterceptOrder(rawValue: 1000)

        public static func < (lhs: InterceptOrder, rhs: InterceptOrder) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What an intercept did with the event.
    public enum InterceptResult: Sendable, Equatable {
        /// Later intercepts and AppKit get the event.
        case pass
        /// The event stops here: no later intercept and no responder gets it (observers already had it,
        /// and after-dispatch observers still get it).
        case consume
    }

    /// The windows a subscription hears.
    public enum WindowScope {
        /// Events of every window, and events with no window.
        case anyWindow
        /// Events of `window` and of its child windows other than panels (a Chromium page window
        /// belongs to the cmux window that holds it).
        case window(NSWindow)
    }
}
