import Foundation

/// Parses the NUL-delimited Git output used by workspace changes.
struct WorkspaceChangesParser {
    struct NameStatusEntry: Sendable, Equatable {
        let path: String
        let oldPath: String?
        let status: WorkspaceChangeStatus
    }

    struct NumstatEntry: Sendable, Equatable {
        let path: String
        let additions: Int
        let deletions: Int
        let isBinary: Bool
    }

    func nameStatusEntries(from data: Data) -> [NameStatusEntry] {
        let fields = nulDelimitedFields(from: data)
        var entries: [NameStatusEntry] = []
        var index = 0
        while index < fields.count {
            let token = fields[index]
            index += 1
            guard let code = token.first else { continue }
            if code == "R" || code == "C" {
                guard index + 1 < fields.count else { break }
                let oldPath = fields[index]
                let path = fields[index + 1]
                index += 2
                entries.append(NameStatusEntry(
                    path: path,
                    oldPath: code == "R" ? oldPath : nil,
                    status: code == "R" ? .renamed : .added
                ))
            } else {
                guard index < fields.count else { break }
                let path = fields[index]
                index += 1
                guard let status = status(for: code) else { continue }
                entries.append(NameStatusEntry(path: path, oldPath: nil, status: status))
            }
        }
        return entries
    }

    func numstatEntries(from data: Data) -> [NumstatEntry] {
        let fields = nulDelimitedFields(from: data)
        var entries: [NumstatEntry] = []
        var index = 0
        while index < fields.count {
            let token = fields[index]
            index += 1
            let parts = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let path: String
            if parts[2].isEmpty {
                guard index + 1 < fields.count else { break }
                _ = fields[index]
                path = fields[index + 1]
                index += 2
            } else {
                path = String(parts[2])
            }
            let isBinary = parts[0] == "-" || parts[1] == "-"
            entries.append(NumstatEntry(
                path: path,
                additions: isBinary ? 0 : Int(parts[0]) ?? 0,
                deletions: isBinary ? 0 : Int(parts[1]) ?? 0,
                isBinary: isBinary
            ))
        }
        return entries
    }

    func untrackedPaths(from data: Data) -> [String] {
        nulDelimitedFields(from: data)
    }

    func singleNumstatEntry(from data: Data, path: String) -> NumstatEntry? {
        guard let line = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \Character.isNewline)
            .first else { return nil }
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let isBinary = parts[0] == "-" || parts[1] == "-"
        return NumstatEntry(
            path: path,
            additions: isBinary ? 0 : Int(parts[0]) ?? 0,
            deletions: isBinary ? 0 : Int(parts[1]) ?? 0,
            isBinary: isBinary
        )
    }

    private func nulDelimitedFields(from data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true).map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    private func status(for code: Character) -> WorkspaceChangeStatus? {
        switch code {
        case "A", "C": .added
        case "D": .deleted
        case "M", "T", "U": .modified
        default: nil
        }
    }
}
