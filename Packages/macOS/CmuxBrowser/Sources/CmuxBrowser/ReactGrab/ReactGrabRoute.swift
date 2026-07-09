public import Foundation

/// The browser + optional return-terminal panels React Grab acts on for one
/// toggle.
///
/// The app target resolves this from the focused panel layout (the focused
/// browser, or the lone browser plus the focused terminal it should paste back
/// to) and hands it to ``ReactGrabController``. The package owns the toggle
/// orchestration; route computation stays app-side because it is keyed on the
/// app-target panel-type model.
public struct ReactGrabRoute: Equatable, Sendable {
    /// The browser panel React Grab activates in.
    public let browserPanelId: UUID

    /// The terminal panel a successful copy pastes back into, when the route
    /// originated from a focused terminal; `nil` when the browser was focused
    /// directly (no pasteback target).
    public let returnTerminalPanelId: UUID?

    /// Creates a route.
    /// - Parameters:
    ///   - browserPanelId: the browser panel React Grab activates in.
    ///   - returnTerminalPanelId: the pasteback target terminal, if any.
    public init(browserPanelId: UUID, returnTerminalPanelId: UUID?) {
        self.browserPanelId = browserPanelId
        self.returnTerminalPanelId = returnTerminalPanelId
    }
}
