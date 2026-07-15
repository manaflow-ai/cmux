/// One `git diff --raw -z` status record.
struct GitRawChange: Sendable, Equatable {
    let path: String
    let oldPath: String?
    let status: DiffFileStatus
}
