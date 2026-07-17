import Foundation

/// Parses NUL-delimited Git plumbing output and batched patch sections.
struct GitOutputParser: Sendable {
    func rawChanges(_ output: String) -> [GitRawChange] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [GitRawChange] = []
        var index = 0
        while index < fields.count {
            let header = fields[index]
            index += 1
            guard let token = header.split(separator: " ").last else { break }
            let statusCode = token.first ?? "M"
            guard index < fields.count else { break }
            let firstPath = fields[index]
            index += 1
            if statusCode == "R" || statusCode == "C" {
                guard index < fields.count else { break }
                let newPath = fields[index]
                index += 1
                changes.append(GitRawChange(
                    path: newPath,
                    oldPath: firstPath,
                    status: statusCode == "R" ? .renamed : .copied
                ))
            } else {
                changes.append(GitRawChange(
                    path: firstPath,
                    oldPath: nil,
                    status: status(statusCode)
                ))
            }
        }
        return changes
    }

    func numstats(_ output: String) -> [GitNumstat] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var records: [GitNumstat] = []
        var index = 0
        while index < fields.count {
            let header = fields[index]
            index += 1
            if header.isEmpty { continue }
            let pieces = header.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count >= 3 else { continue }
            let isBinary = pieces[0] == "-" || pieces[1] == "-"
            let additions = Int(pieces[0]) ?? 0
            let deletions = Int(pieces[1]) ?? 0
            if pieces[2].isEmpty {
                guard index + 1 < fields.count else { break }
                let oldPath = fields[index]
                let path = fields[index + 1]
                index += 2
                records.append(GitNumstat(
                    path: path,
                    oldPath: oldPath,
                    additions: additions,
                    deletions: deletions,
                    isBinary: isBinary
                ))
            } else {
                records.append(GitNumstat(
                    path: pieces[2],
                    oldPath: nil,
                    additions: additions,
                    deletions: deletions,
                    isBinary: isBinary
                ))
            }
        }
        return records
    }

    func patchSections(_ output: String) -> [Data] {
        guard !output.isEmpty else { return [] }
        let marker = "\ndiff --git "
        let pieces = output.components(separatedBy: marker)
        return pieces.enumerated().compactMap { index, piece in
            let section = index == 0 ? piece : "diff --git " + piece
            return section.hasPrefix("diff --git ") ? Data(section.utf8) : nil
        }
    }

    private func status(_ code: Character) -> DiffFileStatus {
        switch code {
        case "A": .added
        case "D": .deleted
        default: .modified
        }
    }
}
