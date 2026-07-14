import Foundation

/// Parses Git's stable worktree porcelain format into value snapshots.
struct WorktreeSidebarPorcelainParser: Sendable {
    func parse(_ output: String) -> [WorktreeSidebarWorktree] {
        output.contains("\0")
            ? parse(fields: output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init))
            : parse(fields: output.components(separatedBy: .newlines))
    }

    private func parse(fields: [String]) -> [WorktreeSidebarWorktree] {
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

        for field in fields {
            if field.isEmpty {
                flush()
            } else if field.hasPrefix("worktree ") {
                if record.path != nil { flush() }
                record.path = String(field.dropFirst("worktree ".count))
            } else if field.hasPrefix("HEAD ") {
                record.head = String(field.dropFirst("HEAD ".count))
            } else if field.hasPrefix("branch ") {
                record.branchRef = String(field.dropFirst("branch ".count))
            } else if field == "detached" {
                record.isDetached = true
            } else if field == "bare" {
                record.isBare = true
            } else if field == "locked" || field.hasPrefix("locked ") {
                record.isLocked = true
                record.lockReason = Self.suffix(after: "locked", in: field)
            } else if field == "prunable" || field.hasPrefix("prunable ") {
                record.isPrunable = true
                record.prunableReason = Self.suffix(after: "prunable", in: field)
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
