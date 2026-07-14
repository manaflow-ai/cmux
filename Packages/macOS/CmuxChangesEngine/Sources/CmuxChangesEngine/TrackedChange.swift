/// Line statistics joined with raw status metadata for one tracked path.
struct TrackedChange: Sendable {
    let path: String
    let oldPath: String?
    let status: ChangesFileStatus
    let additions: Int
    let deletions: Int
    let isBinary: Bool
}
