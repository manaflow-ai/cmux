import CmuxNextRemoteFetch
import Foundation

/// What the host fetches after the reader approves a markdown document's remote images. The host
/// fetch replaces `img-src https:`, so the page CSP stays strict. A document chose the URL, so the
/// fetch follows the network rules of ``GuardedRemoteFetch`` (https only, no URL credentials, no
/// `localhost` or `.local` names, every address public and the connection pinned to a checked one,
/// at most ``GuardedRemoteFetch/maximumRedirects`` redirects each checked the same way), image
/// types only, at most ``maximumBytes``.
nonisolated enum RemoteImagePolicy {
    static let maximumBytes = 10 * 1024 * 1024
    static let timeout: Duration = .seconds(15)

    static let imageTypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/svg+xml", "image/bmp",
        "image/x-icon", "image/vnd.microsoft.icon", "image/apng",
    ]

    /// The URL itself may be fetched (its resolved addresses are checked when it is fetched).
    static func allows(_ url: URL) -> Bool { GuardedRemoteFetch.allows(url) }

    /// The normalized image type of a `Content-Type` value, nil for anything that is not an image.
    static func imageType(_ value: String?) -> String? {
        guard let base = value?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
              imageTypes.contains(base) else { return nil }
        return base
    }

    /// The URL as one path component: base64url without padding.
    static func encode(_ url: URL) -> String {
        Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ component: String) -> URL? {
        var text = component.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), let string = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: string)
    }
}
