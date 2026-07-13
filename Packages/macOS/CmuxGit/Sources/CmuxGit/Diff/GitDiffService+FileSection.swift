import Foundation

extension GitDiffService {
    /// A single-file RPC must never return multiple `diff --git` sections,
    /// even when a stale rename source and destination are both independently
    /// changed. Diff content lines always carry a unified-diff marker, so only
    /// an actual file-section header can start with this prefix.
    static func hasExactlyOneFileSection(_ output: String) -> Bool {
        var sectionCount = 0
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("diff --git ") {
            sectionCount += 1
            if sectionCount > 1 { return false }
        }
        return sectionCount == 1
    }

    /// Supplying `oldPath` asserts a rename. Requiring Git's rename metadata
    /// prevents two unrelated changes from masquerading as that one rename.
    static func hasRenameHeaders(_ output: String) -> Bool {
        var hasRenameFrom = false
        var hasRenameTo = false
        for line in output.split(whereSeparator: \.isNewline) {
            hasRenameFrom = hasRenameFrom || line.hasPrefix("rename from ")
            hasRenameTo = hasRenameTo || line.hasPrefix("rename to ")
        }
        return hasRenameFrom && hasRenameTo
    }
}
