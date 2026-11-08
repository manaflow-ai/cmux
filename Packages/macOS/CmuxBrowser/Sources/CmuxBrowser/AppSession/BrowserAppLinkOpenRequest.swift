public import Foundation

/// Resolves links that explicitly request a full browser pane in cmux.
public struct BrowserAppLinkOpenRequest: Equatable, Sendable {
    /// The query item that opts a web link into native browser opening.
    public static let queryItemName = "cmux_open_in_browser"

    /// The supported placement value for a new right-side browser pane.
    public static let splitRightValue = "split-right"

    /// The destination with the native-only query item removed.
    public let destinationURL: URL

    /// Resolves an allowed same-origin web link into a browser destination.
    public init?(url: URL, webOrigin: URL) {
        guard BrowserAppWebOrigin(webOrigin).contains(url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: {
                  $0.name == Self.queryItemName && $0.value == Self.splitRightValue
              }) == true else {
            return nil
        }

        components.queryItems = components.queryItems?.filter {
            $0.name != Self.queryItemName
        }
        if components.queryItems?.isEmpty == true {
            components.queryItems = nil
        }
        guard let destinationURL = components.url else { return nil }
        self.destinationURL = destinationURL
    }
}
