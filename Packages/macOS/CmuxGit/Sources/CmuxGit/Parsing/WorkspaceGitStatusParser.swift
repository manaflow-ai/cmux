import Foundation

/// Parses and joins Git porcelain and numstat streams without filesystem access.
struct WorkspaceGitStatusParser: Sendable {
    func parse(
        porcelain: String,
        trackedNumstat: String,
        untrackedStatsByPath: [String: WorkspaceGitNumstatEntry]
    ) throws -> [WorkspaceGitStatusFile] {
        try parse(
            porcelainEntries: parsePorcelain(porcelain),
            trackedNumstat: trackedNumstat,
            untrackedStatsByPath: untrackedStatsByPath
        )
    }

    func parse(
        porcelainEntries: [WorkspaceGitPorcelainEntry],
        trackedNumstat: String,
        untrackedStatsByPath: [String: WorkspaceGitNumstatEntry]
    ) throws -> [WorkspaceGitStatusFile] {
        let trackedEntries = try parseNumstat(trackedNumstat)
        var numstatByPath = Dictionary(uniqueKeysWithValues: trackedEntries.map { ($0.path, $0) })
        numstatByPath.merge(untrackedStatsByPath) { _, untracked in untracked }

        return porcelainEntries.map { entry in
            let stats = numstatByPath[entry.path]
            return WorkspaceGitStatusFile(
                path: entry.path,
                oldPath: entry.oldPath ?? stats?.oldPath,
                status: entry.status,
                additions: stats?.additions ?? 0,
                deletions: stats?.deletions ?? 0,
                binary: stats?.binary ?? false,
                untracked: entry.untracked
            )
        }
    }

    func parsePorcelain(_ output: String) throws -> [WorkspaceGitPorcelainEntry] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [WorkspaceGitPorcelainEntry] = []
        var index = 0

        while index < records.count {
            let record = records[index]
            guard record.count >= 3 else {
                throw WorkspaceGitParseError.malformedPorcelain
            }
            let x = record[record.startIndex]
            let yIndex = record.index(after: record.startIndex)
            let y = record[yIndex]
            let separatorIndex = record.index(after: yIndex)
            guard record[separatorIndex] == " " else {
                throw WorkspaceGitParseError.malformedPorcelain
            }
            let pathStart = record.index(after: separatorIndex)
            let path = String(record[pathStart...])
            guard !path.isEmpty else {
                throw WorkspaceGitParseError.malformedPorcelain
            }

            let untracked = x == "?" && y == "?"
            let renamed = x == "R" || y == "R"
            let copied = x == "C" || y == "C"
            let oldPath: String?
            if renamed || copied {
                index += 1
                guard index < records.count, !records[index].isEmpty else {
                    throw WorkspaceGitParseError.malformedPorcelain
                }
                oldPath = records[index]
            } else {
                oldPath = nil
            }

            let status: String
            if untracked {
                status = "A"
            } else if renamed {
                status = "R"
            } else if copied {
                // Match GitStatusProvider: a copy is a newly added destination,
                // while oldPath preserves its source for display and diagnostics.
                status = "A"
            } else if x == "A" {
                status = "A"
            } else if x == "D" || y == "D" {
                status = "D"
            } else {
                status = "M"
            }
            entries.append(
                WorkspaceGitPorcelainEntry(
                    path: path,
                    oldPath: oldPath,
                    status: status,
                    untracked: untracked
                )
            )
            index += 1
        }
        return entries
    }

    func parseNumstat(_ output: String) throws -> [WorkspaceGitNumstatEntry] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var entries: [WorkspaceGitNumstatEntry] = []
        var index = 0

        while index < records.count {
            let record = records[index]
            if record.isEmpty, index == records.count - 1 {
                break
            }
            guard let firstTab = record.firstIndex(of: "\t") else {
                throw WorkspaceGitParseError.malformedNumstat
            }
            let afterFirstTab = record.index(after: firstTab)
            guard let secondTab = record[afterFirstTab...].firstIndex(of: "\t") else {
                throw WorkspaceGitParseError.malformedNumstat
            }
            let addedField = String(record[..<firstTab])
            let deletedField = String(record[afterFirstTab..<secondTab])
            let pathStart = record.index(after: secondTab)
            let pathField = String(record[pathStart...])
            let binary = addedField == "-" && deletedField == "-"
            let additions: Int
            let deletions: Int
            if binary {
                additions = 0
                deletions = 0
            } else {
                guard let parsedAdditions = Int(addedField), let parsedDeletions = Int(deletedField) else {
                    throw WorkspaceGitParseError.malformedNumstat
                }
                additions = parsedAdditions
                deletions = parsedDeletions
            }

            let path: String
            let oldPath: String?
            if pathField.isEmpty {
                guard index + 2 < records.count,
                      !records[index + 1].isEmpty,
                      !records[index + 2].isEmpty else {
                    throw WorkspaceGitParseError.malformedNumstat
                }
                oldPath = records[index + 1]
                path = records[index + 2]
                index += 2
            } else {
                oldPath = nil
                path = pathField
            }

            entries.append(
                WorkspaceGitNumstatEntry(
                    path: path,
                    oldPath: oldPath,
                    additions: additions,
                    deletions: deletions,
                    binary: binary
                )
            )
            index += 1
        }
        return entries
    }
}
