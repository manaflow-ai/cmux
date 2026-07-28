public import Foundation

/// Selects the browser identity that best matches an embedded WebKit view for
/// each top-level destination.
public struct BrowserUserAgentPolicy: Sendable {
    /// The policy derived from the Safari installation and operating system on this Mac.
    public static let system = BrowserUserAgentPolicy()

    /// A Safari-compatible user-agent string for sites that gate browser support.
    public let safariCompatibleUserAgent: String

    /// Creates a policy using an explicit Safari version.
    ///
    /// Invalid versions fall back to the Safari generation associated with the
    /// current operating system.
    ///
    /// - Parameter safariVersion: A numeric dot-separated Safari version.
    public init(safariVersion: String) {
        let components = safariVersion.split(separator: ".", omittingEmptySubsequences: false)
        let resolvedVersion: String
        if !components.isEmpty,
           components.allSatisfy({ !$0.isEmpty && Int($0) != nil }) {
            resolvedVersion = components.joined(separator: ".")
        } else {
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            if osVersion.majorVersion >= 26 {
                resolvedVersion = "\(osVersion.majorVersion).\(osVersion.minorVersion)"
            } else if osVersion.majorVersion >= 11 {
                resolvedVersion = "\(osVersion.majorVersion + 3).0"
            } else {
                resolvedVersion = "13.1"
            }
        }
        safariCompatibleUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/\(resolvedVersion) Safari/605.1.15"
    }

    /// Creates a policy using the installed Safari version when available.
    public init() {
        let safariBundleURL = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        let installedVersion = Bundle(url: safariBundleURL)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.init(safariVersion: installedVersion ?? "")
    }

    /// Returns the custom identity for a top-level destination.
    ///
    /// Google Sheets and non-web destinations return `nil` so WebKit constructs
    /// its native embedded identity.
    ///
    /// - Parameter url: The destination of the top-level navigation.
    /// - Returns: A Safari-compatible user agent, or `nil` for embedded identity.
    public func customUserAgent(for url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let host = url.host?.lowercased() else { return safariCompatibleUserAgent }
        let isSheetsHost = host == "sheets.google.com" || host == "spreadsheets.google.com"
        let isSheetsPath = host == "docs.google.com"
            && url.path.split(separator: "/", omittingEmptySubsequences: true).first?
                .lowercased() == "spreadsheets"
        return isSheetsHost || isSheetsPath ? nil : safariCompatibleUserAgent
    }
}
