import Foundation

/// Creates pages for one engine.
///
/// The WebKit provider ships in this package. The Chromium provider ships in
/// the CEF package, which depends on this one; the app registers it in its
/// ``BrowserEngineRegistry`` when the runtime is bundled.
@MainActor
public protocol BrowserEngineProviding: AnyObject {
    /// The engine this provider creates pages for.
    var kind: BrowserEngineKind { get }
    /// Whether the engine can create pages now.
    var availability: BrowserEngineAvailability { get }
    /// The features pages of this engine support.
    var capabilities: BrowserEngineCapabilities { get }

    /// Creates a page.
    /// - Parameter configuration: The page's profile, initial URL and state.
    /// - Returns: A new page; the caller hosts its content view.
    /// - Throws: ``BrowserEngineError/unavailable(_:_:)`` when the engine
    ///   cannot create pages.
    func makePage(_ configuration: BrowserPageConfiguration) throws -> any BrowserPage
}
