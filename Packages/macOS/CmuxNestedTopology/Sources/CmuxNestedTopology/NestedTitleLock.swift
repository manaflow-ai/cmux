/// Explicit native-title lock for one association record.
///
/// When locked, writers must not overwrite the title from heuristics or stale polls.
public struct NestedTitleLock: Hashable, Codable, Sendable {
    /// Whether the title is locked against overwrite.
    public var isLocked: Bool
    /// Locked title value when present.
    public var lockedTitle: String?
    /// Authority that established the lock.
    public var authority: NestedTitleAuthority

    enum CodingKeys: String, CodingKey {
        case isLocked = "is_locked"
        case lockedTitle = "locked_title"
        case authority
    }

    /// Creates a title lock value.
    public init(
        isLocked: Bool,
        lockedTitle: String? = nil,
        authority: NestedTitleAuthority
    ) {
        self.isLocked = isLocked
        self.lockedTitle = lockedTitle
        self.authority = authority
    }

    /// Active lock with an authoritative title.
    public static func locked(_ title: String, authority: NestedTitleAuthority) -> NestedTitleLock {
        NestedTitleLock(isLocked: true, lockedTitle: title, authority: authority)
    }
}
