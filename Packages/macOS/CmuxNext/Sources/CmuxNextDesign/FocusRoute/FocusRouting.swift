public import AppKit

/// A window that judges and records each keyboard move it is asked for (the app's main window):
/// ``FocusRoute`` hands it the route with the call, held in ``routeInFlight`` while AppKit runs
/// it, so the window's gate knows who started the move and its focus log names the caller and
/// the reason. Conforming takes only the stored property.
@MainActor
public protocol FocusRouting: NSWindow {
    /// The route of the move being made now (nil outside a routed call).
    var routeInFlight: FocusRoute? { get set }
}

extension FocusRouting {
    /// Makes `responder` the first responder for `route`; false when refused.
    ///
    /// - Parameters:
    ///   - responder: The responder asked for.
    ///   - route: Who asked, and why.
    /// - Returns: Whether the window made it its first responder.
    public func makeFirstResponder(_ responder: NSResponder?, through route: FocusRoute) -> Bool {
        let outer = routeInFlight
        routeInFlight = route
        defer { routeInFlight = outer }
        return makeFirstResponder(responder) // focus-route: the routed call itself
    }

    /// Becomes the key window for `route` (ordered front too when `front`).
    ///
    /// - Parameters:
    ///   - route: Who asked, and why.
    ///   - front: Also order the window front.
    public func makeKey(through route: FocusRoute, front: Bool) {
        let outer = routeInFlight
        routeInFlight = route
        defer { routeInFlight = outer }
        if front { makeKeyAndOrderFront(nil) } else { makeKey() } // focus-route: the routed call itself
    }
}
