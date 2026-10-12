import Foundation

#if DEBUG
/// A JavaScript dialog (`Dialog`).
public nonisolated struct RbDialog: Sendable, Equatable, Decodable {
    /// `alert`, `confirm`, `prompt`, `beforeunload`.
    public var kind: String
    public var origin: String
    public var message: String
    public var defaultText: String?
    public var isReload: Bool

    private enum CodingKeys: String, CodingKey {
        case kind, origin, message
        case defaultText = "default_text", isReload = "is_reload"
    }
}
#endif
