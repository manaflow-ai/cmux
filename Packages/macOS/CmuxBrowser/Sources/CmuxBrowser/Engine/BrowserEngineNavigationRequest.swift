public import Foundation

/// An engine-neutral navigation request awaiting cmux policy evaluation.
public struct BrowserEngineNavigationRequest: Sendable {
    /// The original browser request represented by the engine event.
    public let request: URLRequest

    /// The cmux destination requested by the page.
    public let disposition: BrowserEngineNavigationDisposition

    /// Creates a navigation request for policy evaluation.
    ///
    /// - Parameters:
    ///   - request: The original request represented by the browser engine.
    ///   - disposition: The current-pane or new-tab destination requested by the page.
    public init(
        request: URLRequest,
        disposition: BrowserEngineNavigationDisposition
    ) {
        self.request = request
        self.disposition = disposition
    }
}
