import Darwin
import Foundation

/// Identifies one destination entry created by a worktree-include copy invocation.
struct WorktreeIncludeCreatedItem {
    let relativePath: String
    let device: dev_t
    let inode: ino_t
    let isDirectory: Bool
    let directoryMetadataSourceRelativePath: String?
}
