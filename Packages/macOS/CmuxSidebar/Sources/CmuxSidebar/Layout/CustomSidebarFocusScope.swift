public import CmuxFoundation
public import Foundation

/// The one source a web sidebar's focus bridge is armed for.
///
/// A sidebar can name any page, and most of them have no business selecting the user's workspaces.
/// Arming is therefore a property of the *source*, decided once before the page loads: a local
/// document under the user's own sidebars directory, or a page served from a literal loopback
/// address. Everything else — a public site, a DNS name that merely resolves to loopback today, a
/// custom scheme — produces no scope, and a source with no scope never has the handler registered
/// at all.
///
/// The same value is then the navigation lock and the dispatch check, so the page that can call the
/// bridge is by construction the page arming inspected. A document may not navigate to a different
/// file or out to the network, and a loopback page may not leave its own origin; either attempt is
/// cancelled rather than allowed to inherit the handler.
public enum CustomSidebarFocusScope: Equatable, Sendable {
    /// A local document, identified by its standardized file URL.
    case document(URL)
    /// A page served from a literal loopback origin.
    case loopback(CustomSidebarLoopbackOrigin)

    /// Arms a scope for a web sidebar source, or returns `nil` when the source does not qualify.
    ///
    /// - Parameter source: The page the sidebar was asked to render.
    public init?(source: CustomSidebarWebSource) {
        switch source {
        case let .document(fileURL):
            guard fileURL.isFileURL else { return nil }
            self = .document(fileURL.standardizedFileURL)
        case let .remote(url):
            guard let origin = CustomSidebarLoopbackOrigin(url: url) else { return nil }
            self = .loopback(origin)
        }
    }

    /// Whether a main-frame navigation may proceed.
    ///
    /// Subframes are not constrained here: they cannot reach the handler (every dispatch requires
    /// the main frame), and a sidebar embedding a third-party iframe is a legitimate thing to do.
    ///
    /// - Parameters:
    ///   - url: The navigation target, or `nil` when the action carries none.
    ///   - isMainFrame: Whether the navigation targets the main frame.
    /// - Returns: `true` when the navigation stays inside the armed source.
    public func permitsNavigation(to url: URL?, isMainFrame: Bool) -> Bool {
        guard isMainFrame else { return true }
        guard let url else { return false }
        switch self {
        case let .document(fileURL):
            // A redirect from the document to anything else — another file, or an http page that
            // would then inherit the handler — leaves the armed source.
            return url.isFileURL && url.standardizedFileURL == fileURL
        case let .loopback(origin):
            return origin.matches(url: url)
        }
    }

    /// Whether a received message may be dispatched.
    ///
    /// Arming and the navigation lock are both decided before the message arrives, so this is the
    /// check that the page *actually speaking* is still the armed one: the message came from the
    /// main frame, that frame's security origin belongs to the scope, and the web view's current
    /// URL does too. A page that got somewhere else — through a redirect the delegate did not see,
    /// or a document that rewrote its own location — fails here even though the handler is still
    /// registered.
    ///
    /// - Parameters:
    ///   - isMainFrame: Whether the sending frame is the main frame.
    ///   - frameOriginScheme: The sending frame's security-origin scheme.
    ///   - frameOriginHost: The sending frame's security-origin host.
    ///   - frameOriginPort: The sending frame's security-origin port (`0` means the scheme default).
    ///   - webViewURL: The web view's current URL.
    /// - Returns: `true` when every check passes.
    public func permitsDispatch(
        isMainFrame: Bool,
        frameOriginScheme: String?,
        frameOriginHost: String?,
        frameOriginPort: Int?,
        webViewURL: URL?
    ) -> Bool {
        guard isMainFrame else { return false }
        switch self {
        case let .document(fileURL):
            // A file document's security origin is opaque: WebKit reports the `file` scheme with an
            // empty host, so identity has to come from the loaded URL, which the navigation lock
            // keeps pinned to this exact file.
            guard frameOriginScheme?.lowercased() == "file" else { return false }
            guard let webViewURL, webViewURL.isFileURL, webViewURL.standardizedFileURL == fileURL else {
                return false
            }
            return true
        case let .loopback(origin):
            guard let frameOrigin = CustomSidebarLoopbackOrigin(
                scheme: frameOriginScheme,
                host: frameOriginHost,
                port: frameOriginPort
            ), frameOrigin == origin else { return false }
            guard let webViewURL, origin.matches(url: webViewURL) else { return false }
            return true
        }
    }
}
