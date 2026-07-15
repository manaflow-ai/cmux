/// One `git diff --numstat -z` record.
struct GitNumstat: Sendable, Equatable {
    let path: String
    let oldPath: String?
    let additions: Int
    let deletions: Int
    let isBinary: Bool
}
