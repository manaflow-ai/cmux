import Foundation

/// Fetches bounded metadata for a remote browser page.
public protocol BrowserPageMetadataFetching: Sendable {
    /// Fetches the HTML title for a remote page.
    ///
    /// - Parameter url: The HTTP or HTTPS page URL.
    /// - Returns: A trimmed page title, or `nil` when the page has no usable title.
    /// - Throws: `CancellationError` when the caller cancels the operation.
    func title(for url: URL) async throws -> String?
}
