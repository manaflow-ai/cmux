public import Foundation

/// A navigation request awaiting cmux policy evaluation.
public struct BrowserEngineNavigationRequest: Sendable {
    /// The URL request emitted by the browser engine.
    public let request: URLRequest

    /// The destination requested by the page.
    public let disposition: BrowserEngineNavigationDisposition

    /// Creates a navigation policy request.
    ///
    /// - Parameters:
    ///   - request: The original engine request.
    ///   - disposition: Whether the page requested the current tab or a new tab.
    public init(
        request: URLRequest,
        disposition: BrowserEngineNavigationDisposition
    ) {
        self.request = request
        self.disposition = disposition
    }
}
