/// One unambiguous pre-v3 backup collection eligible for one-time adoption.
public enum MobileIOSLegacyBackupScope: Equatable, Sendable {
    /// The former App Store collection that did not carry a scope header.
    case unscoped

    /// A former development collection identified by its exact v2 scope.
    case scoped(String)

    /// The legacy request header value, or `nil` for the unscoped collection.
    public var headerValue: String? {
        switch self {
        case .unscoped: nil
        case .scoped(let value): value
        }
    }
}
