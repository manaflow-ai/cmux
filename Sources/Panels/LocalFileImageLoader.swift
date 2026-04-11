import Foundation

/// Classifies swift-markdown-ui image destinations so `LocalFileImageProvider`
/// can dispatch to the right loader (local disk, remote fetch, or placeholder).
enum LocalFileImageLoader {
    enum Kind: Equatable {
        case local(URL)
        case remote(URL)
        case unsupported
    }

    static func classify(_ url: URL) -> Kind {
        // swift-markdown-ui hands us relative URLs resolved against `imageBaseURL`;
        // normalize to absolute so scheme/path checks don't fall through to cwd.
        let resolved = url.absoluteURL

        if let scheme = resolved.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                return .remote(resolved)
            case "file":
                // `URL.path` excludes query/fragment and percent-decodes, so
                // rebuilding via `fileURLWithPath` yields a canonical file URL.
                return .local(URL(fileURLWithPath: resolved.path))
            default:
                return .unsupported
            }
        }

        // Defensive: the library normally normalizes scheme-less inputs before
        // they reach us.
        if resolved.path.hasPrefix("/") {
            return .local(URL(fileURLWithPath: resolved.path))
        }

        return .unsupported
    }
}
