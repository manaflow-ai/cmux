/// The presentation and viewport ownership decisions for one native scroll
/// gesture. UIKit can deliver a gesture across render-grid updates, so the
/// route is captured once and remains stable through deceleration.
struct TerminalScrollGestureRoute: Equatable, Sendable {
    struct Resolution: Equatable, Sendable {
        let appliesLocally: Bool
        let ownsLocalPrimaryScreen: Bool

        var usesPixelPath: Bool {
            appliesLocally && ownsLocalPrimaryScreen
        }
    }

    private(set) var authority: TerminalScrollPresentationAuthority?
    private(set) var ownsLocalPrimaryScreen = false

    /// Starts a new UIKit drag. The next flush captures the current
    /// presentation authority and may claim the local pixel path once primary
    /// screen ownership is confirmed.
    mutating func begin() {
        authority = nil
        ownsLocalPrimaryScreen = false
    }

    /// Drops the current route after an explicit screen or surface change.
    mutating func reset() {
        begin()
    }

    /// Resolves the route without allowing a later render-grid update to
    /// change the units of an in-flight gesture.
    mutating func resolve(
        currentAuthority: TerminalScrollPresentationAuthority,
        currentOwnsLocalPrimaryScreen: Bool
    ) -> Resolution {
        if authority == nil {
            authority = currentAuthority
        }
        if authority?.appliesLocally == true, currentOwnsLocalPrimaryScreen {
            ownsLocalPrimaryScreen = true
        }
        return Resolution(
            appliesLocally: authority?.appliesLocally == true,
            ownsLocalPrimaryScreen: ownsLocalPrimaryScreen
        )
    }
}
