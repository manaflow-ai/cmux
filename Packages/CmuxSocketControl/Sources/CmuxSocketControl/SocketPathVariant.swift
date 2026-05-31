/// A flavor of the cmux app, used to derive per-flavor socket and marker file paths.
///
/// Stable, nightly, staging, and dev builds each run side by side with isolated control
/// sockets so they never collide. The associated `slug` (when present) further scopes
/// nightly/staging/dev builds that carry a tag in their bundle identifier or `CMUX_TAG`.
public enum SocketPathVariant: Equatable, Sendable {
    /// The shipping release build.
    case stable
    /// A nightly build, optionally tag-scoped by `slug`.
    case nightly(slug: String?)
    /// A staging build, optionally tag-scoped by `slug`.
    case staging(slug: String?)
    /// A local debug/dev build, optionally tag-scoped by `slug`.
    case dev(slug: String?)

    /// The Application Support marker file name that records this variant's last socket path.
    public var appSupportFileName: String {
        switch self {
        case .stable:
            return SocketPathMarkerFiles.stableAppSupportFileName
        case .nightly(let slug):
            if let slug {
                return "nightly-\(slug)-last-socket-path"
            }
            return "nightly-last-socket-path"
        case .staging(let slug):
            if let slug {
                return "staging-\(slug)-last-socket-path"
            }
            return "staging-last-socket-path"
        case .dev(let slug):
            if let slug {
                return "dev-\(slug)-last-socket-path"
            }
            return "dev-last-socket-path"
        }
    }

    /// The `/tmp` marker file path that records this variant's last socket path.
    public var tmpPath: String {
        switch self {
        case .stable:
            return SocketPathMarkerFiles.stableTmpPath
        case .nightly(let slug):
            if let slug {
                return "/tmp/cmux-nightly-\(slug)-last-socket-path"
            }
            return "/tmp/cmux-nightly-last-socket-path"
        case .staging(let slug):
            if let slug {
                return "/tmp/cmux-staging-\(slug)-last-socket-path"
            }
            return "/tmp/cmux-staging-last-socket-path"
        case .dev(let slug):
            if let slug {
                return "/tmp/cmux-dev-\(slug)-last-socket-path"
            }
            return "/tmp/cmux-dev-last-socket-path"
        }
    }

    /// Whether this is a local debug/dev build.
    public var isDev: Bool {
        if case .dev = self { return true }
        return false
    }
}
