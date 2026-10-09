import Foundation

/// Exact-URL record of the remote images a reader approved in one markdown
/// view.
///
/// The viewer shell rewrites approved images to the `cmux-remote-image`
/// scheme, but page script can request any URL on that scheme. The native
/// scheme handler therefore fetches only URLs present in this record, and the
/// record is filled only through the viewer's explicit "Load this image"
/// action. Each coordinator owns one record and clears it whenever it loads a
/// new shell document.
public struct MarkdownRemoteImageApprovals: Sendable {
    private var approvedURLs: Set<String> = []

    public init() {}

    /// Records approval for exactly `rawURL`. Returns the approved URL, or nil
    /// when the URL is not a remote image the viewer may ever load.
    @discardableResult
    public mutating func approve(_ rawURL: String) -> URL? {
        guard let url = URL(string: rawURL),
              MarkdownRemoteImageSecurity().isPotentiallySafeRemoteImageURL(url) else {
            return nil
        }
        approvedURLs.insert(url.absoluteString)
        return url
    }

    public func isApproved(_ url: URL) -> Bool {
        approvedURLs.contains(url.absoluteString)
    }

    /// The remote URL a `cmux-remote-image` request asks for, only when that
    /// exact URL was approved in this view.
    public func approvedRemoteImageURL(for requestURL: URL) -> URL? {
        guard let remoteURL = MarkdownRemoteImageSecurity().remoteImageURL(from: requestURL),
              isApproved(remoteURL) else {
            return nil
        }
        return remoteURL
    }

    public mutating func revokeAll() {
        approvedURLs.removeAll()
    }

    /// Validates a URL the viewer asks the host to open from a remote-image
    /// placeholder. Only plain web URLs without credentials leave the view.
    public static func openableRemoteImageURL(_ rawURL: String) -> URL? {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.user == nil,
              url.password == nil,
              let host = url.host(percentEncoded: false),
              !host.isEmpty else {
            return nil
        }
        return url
    }
}
