/// Records a bounded Git content digest and whether the underlying stream was empty.
struct WorktreeSidebarGitContentFingerprint: Equatable, Sendable {
    let fingerprint: WorktreeSidebarGitFingerprint
    let hasContent: Bool
}
