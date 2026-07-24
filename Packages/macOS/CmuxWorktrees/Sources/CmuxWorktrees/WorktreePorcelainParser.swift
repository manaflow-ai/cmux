import Foundation

/// Parses the stable output of `git worktree list --porcelain`, with or without `-z`.
public struct WorktreePorcelainParser: Sendable {
    /// Creates a porcelain parser.
    public init() {}

    /// Parses a complete porcelain listing.
    ///
    /// Git emits the main worktree first. Its path becomes the stable repository
    /// path in every returned ``WorktreeIdentity``, even when the command was
    /// invoked from a linked worktree.
    ///
    /// - Parameters:
    ///   - output: Complete `git worktree list --porcelain` standard output.
    ///   - host: The host that produced the listing.
    ///   - fallbackRepoPath: Used only when Git returns no entries.
    /// - Returns: Worktree snapshots in Git's reported order.
    public func parse(
        _ output: String,
        host: WorktreeHostID,
        fallbackRepoPath: String
    ) -> [WorktreeInfo] {
        let records = output.contains("\0")
            ? nulTerminatedRecords(output)
            : lineTerminatedRecords(output)

        let stableRepoPath = records.first?.path ?? fallbackRepoPath
        return records.enumerated().compactMap { index, record in
            guard let path = record.path, !record.isRejected else { return nil }
            let branch = record.branchReference.map { reference in
                let prefix = "refs/heads/"
                return reference.hasPrefix(prefix) ? String(reference.dropFirst(prefix.count)) : reference
            }
            return WorktreeInfo(
                identity: WorktreeIdentity(
                    host: host,
                    repoPath: stableRepoPath,
                    worktreePath: path
                ),
                headOID: record.headOID,
                branch: branch,
                isDetached: record.isDetached,
                isBare: record.isBare,
                isLocked: record.isLocked,
                lockReason: record.lockReason,
                isPrunable: record.isPrunable,
                prunableReason: record.prunableReason,
                isMainWorktree: index == 0
            )
        }
    }

    private func nulTerminatedRecords(_ output: String) -> [WorktreePorcelainRecord] {
        var records: [WorktreePorcelainRecord] = []
        var fields: [String] = []
        for field in output.components(separatedBy: "\0") {
            if field.isEmpty {
                if !fields.isEmpty {
                    records.append(WorktreePorcelainRecord(lines: fields))
                    fields.removeAll(keepingCapacity: true)
                }
            } else {
                fields.append(field)
            }
        }
        if !fields.isEmpty {
            records.append(WorktreePorcelainRecord(lines: fields))
        }
        return records
    }

    private func lineTerminatedRecords(_ output: String) -> [WorktreePorcelainRecord] {
        output
            .components(separatedBy: "\n\n")
            .flatMap { block -> [WorktreePorcelainRecord] in
                let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                return lines.isEmpty ? [] : [WorktreePorcelainRecord(lines: lines, legacyLineMode: true)]
            }
    }
}
