/// A browser page that may host Chromium extensions.
///
/// The Chromium page conforms and returns its host when the engine was set
/// up with extension support; callers ask `page as? any BrowserExtensionHostProviding`.
@MainActor
public protocol BrowserExtensionHostProviding: AnyObject {
    /// The page's extension host, or nil when extensions are not set up.
    var extensionHost: (any BrowserExtensionHosting)? { get }
}
