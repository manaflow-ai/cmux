/// Identifies Git output without retaining the path-sized output itself.
struct WorktreeSidebarGitFingerprint: Equatable, Sendable {
    static let empty = WorktreeSidebarGitFingerprint(
        sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )

    let sha256: String

    var hasContent: Bool { self != .empty }
}
