extension GitDiffService {
    struct FileSystemIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let size: Int64
        let modificationTime: String
        let changeTime: String
    }
}
