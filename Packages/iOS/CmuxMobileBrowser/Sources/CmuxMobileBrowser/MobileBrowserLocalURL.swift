public import Foundation

/// Encodes and decodes the private URL space used by one local WebKit view.
///
/// The codec is an instance so a browser seam owns its scheme configuration;
/// URL construction does not depend on process-global state.
public struct MobileBrowserLocalURLCodec: Sendable {
    /// The private scheme registered only on the owning WebKit instance.
    public let scheme: String

    /// Creates a local URL codec.
    /// - Parameter scheme: The private scheme to encode and decode.
    public init(scheme: String = "cmux-local") {
        self.scheme = scheme
    }

    /// Creates a local resource URL for one panel and logical path.
    /// - Parameters:
    ///   - panelID: The Mac browser panel identifier.
    ///   - path: An absolute logical resource path.
    /// - Returns: A URL in this codec's private scheme, or `nil` for invalid input.
    public func make(panelID: String, path: String) -> URL? {
        guard !panelID.isEmpty, path.hasPrefix("/") else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = panelID
        // `%` is legal in a URL path's allowed-character set, but treating it
        // as already escaped would make a literal filename such as
        // `100%complete.html` decode differently on the Mac. Encode literal
        // percent signs before assigning the percent-encoded path.
        let allowedCharacters = CharacterSet.urlPathAllowed.subtracting(
            CharacterSet(charactersIn: "%")
        )
        components.percentEncodedPath = path.addingPercentEncoding(
            withAllowedCharacters: allowedCharacters
        ) ?? path
        return components.url
    }

    /// Returns the panel and logical path encoded in a local URL.
    /// - Parameter url: A URL created by this codec.
    /// - Returns: The panel identifier and decoded logical path.
    public func components(from url: URL) -> (panelID: String, path: String)? {
        guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame,
              let panelID = url.host,
              !panelID.isEmpty else { return nil }
        // URL.path is decoded exactly once by Foundation. Decoding it again
        // would turn a literal `%20` in a filename into a space.
        let path = url.path
        guard path.hasPrefix("/") else { return nil }
        return (panelID, path)
    }
}
