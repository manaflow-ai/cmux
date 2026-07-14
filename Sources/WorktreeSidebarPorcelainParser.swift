import Foundation

/// Parses Git's stable worktree porcelain format into value snapshots.
struct WorktreeSidebarPorcelainParser: Sendable {
    func parse(_ output: String) -> [WorktreeSidebarWorktree] {
        var parsed: [WorktreeSidebarWorktree] = []
        var record = Record()

        func flush() {
            guard let path = record.path else {
                record = Record()
                return
            }
            parsed.append(WorktreeSidebarWorktree(
                path: URL(fileURLWithPath: path, isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path,
                head: record.head,
                branchRef: record.branchRef,
                isDetached: record.isDetached,
                isBare: record.isBare,
                isMain: parsed.isEmpty,
                isLocked: record.isLocked,
                lockReason: record.lockReason,
                isPrunable: record.isPrunable,
                prunableReason: record.prunableReason
            ))
            record = Record()
        }

        for line in output.components(separatedBy: .newlines) {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                if record.path != nil { flush() }
                record.path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                record.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                record.branchRef = String(line.dropFirst("branch ".count))
            } else if line == "detached" {
                record.isDetached = true
            } else if line == "bare" {
                record.isBare = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                record.isLocked = true
                record.lockReason = Self.suffix(after: "locked", in: line)
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                record.isPrunable = true
                record.prunableReason = Self.suffix(after: "prunable", in: line)
            }
        }
        flush()
        return parsed
    }

    private static func suffix(after keyword: String, in line: String) -> String? {
        let suffix = line.dropFirst(keyword.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    private struct Record {
        var path: String?
        var head: String?
        var branchRef: String?
        var isDetached = false
        var isBare = false
        var isLocked = false
        var lockReason: String?
        var isPrunable = false
        var prunableReason: String?
    }
}
