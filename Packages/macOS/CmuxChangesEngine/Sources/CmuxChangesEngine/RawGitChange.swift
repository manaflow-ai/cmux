/// Status metadata parsed from Git's NUL-delimited raw diff records.
struct RawGitChange: Sendable {
    let path: String
    let oldPath: String?
    let status: ChangesFileStatus
}
