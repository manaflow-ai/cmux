public import Foundation

/// The page address of a browser tab, shown in the strip's quiet location
/// field while the tab is selected. Only web pages have
/// one: `init?(page:)` turns away the New Tab page, `about:`, `file:`,
/// `chrome:`, `cmux:` and every other internal address, since there is no
/// host to show and the omnibox already presents those its own way.
public struct TabLocation: Hashable, Sendable {
    public var url: URL
    /// The page loaded over https. An http page shows a subtle "not
    /// secure" glyph; a secure one shows none (no lock: quiet by default).
    public var isSecure: Bool

    public init(url: URL, isSecure: Bool) {
        self.url = url
        self.isSecure = isSecure
    }

    /// The location of a page at `url`: http and https addresses with a
    /// plain ASCII host, else nil. A host with percent escapes or non-ASCII
    /// characters (`%D0%B0pple.com`) gets no location, so the field never
    /// shows a decoded look-alike; the omnibox still shows the page.
    public init?(page url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: true), !host.isEmpty, !host.contains("%"),
              host.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        self.init(url: url, isSecure: scheme == "https")
    }

    /// The location of a page whose address is `address` (a daemon
    /// record's URL string), else nil.
    public init?(address: String?) {
        self.init(page: address.flatMap(URL.init(string:)))
    }

    /// The prominent part: the lowercased host, bracketed when it is an IPv6
    /// literal, plus a port other than the scheme's default. Hosts stay as
    /// the URL carries them, so an internationalized domain shows in its
    /// punycode (`xn--…`) form rather than as look-alike Unicode. User info
    /// (`user:pass@`) is never shown.
    public var displayHost: String {
        var host = (url.host(percentEncoded: true) ?? "").lowercased()
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        let defaultPort = url.scheme?.lowercased() == "https" ? 443 : 80
        guard let port = url.port, port != defaultPort else { return host }
        return "\(host):\(port)"
    }

    /// The dimmed rest: path, query and fragment as the address carries
    /// them. Empty for a bare root (`https://example.com/`).
    public var displayRest: String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        var rest = components.percentEncodedPath
        if let query = components.percentEncodedQuery { rest += "?" + query }
        if let fragment = components.percentEncodedFragment { rest += "#" + fragment }
        return rest == "/" ? "" : rest
    }

    /// The full address without user info (`user:pass@`): the field's
    /// tooltip and VoiceOver help.
    public var displayURL: String {
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.user = nil
            components.password = nil
            if let stripped = components.url?.absoluteString { return stripped }
        }
        return "\(url.scheme?.lowercased() ?? "https")://\(displayHost)\(displayRest)"
    }
}
