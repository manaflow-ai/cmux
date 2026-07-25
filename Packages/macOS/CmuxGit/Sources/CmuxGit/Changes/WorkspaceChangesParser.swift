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
        var entries: [NameStatusEntry] = []
        forEachNameStatusEntry(from: data) { entries.append($0) }
        return entries
    }

    func forEachNameStatusEntry(
        from data: Data,
        _ visit: (NameStatusEntry) -> Void
    ) {
        var index = data.startIndex
        while let token = nextNulDelimitedField(from: data, index: &index) {
            guard let code = token.first else { continue }
            if code == "R" || code == "C" {
                guard let oldPath = nextNulDelimitedField(from: data, index: &index),
                      let path = nextNulDelimitedField(from: data, index: &index) else {
                    break
                }
                visit(NameStatusEntry(
                    path: path,
                    oldPath: code == "R" ? oldPath : nil,
                    status: code == "R" ? .renamed : .added
                ))
            } else {
                guard let path = nextNulDelimitedField(from: data, index: &index) else {
                    break
                }
                guard let status = status(for: code) else { continue }
                visit(NameStatusEntry(path: path, oldPath: nil, status: status))
            }
        }
    }

    func numstatEntries(from data: Data) -> [NumstatEntry] {
        var entries: [NumstatEntry] = []
        forEachNumstatEntry(from: data) { entries.append($0) }
        return entries
    }

    func forEachNumstatEntry(
        from data: Data,
        _ visit: (NumstatEntry) -> Void
    ) {
        var index = data.startIndex
        while let token = nextNulDelimitedField(from: data, index: &index) {
            let parts = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let path: String
            if parts[2].isEmpty {
                guard nextNulDelimitedField(from: data, index: &index) != nil,
                      let renamedPath = nextNulDelimitedField(from: data, index: &index) else {
                    break
                }
                path = renamedPath
            } else {
                path = String(parts[2])
            }
            let isBinary = parts[0] == "-" || parts[1] == "-"
            visit(NumstatEntry(
                path: path,
                additions: isBinary ? 0 : Int(parts[0]) ?? 0,
                deletions: isBinary ? 0 : Int(parts[1]) ?? 0,
                isBinary: isBinary
            ))
        }
    }

    func untrackedPaths(from data: Data) -> [String] {
        var paths: [String] = []
        forEachUntrackedPath(from: data) { paths.append($0) }
        return paths
    }

    func forEachUntrackedPath(from data: Data, _ visit: (String) -> Void) {
        var index = data.startIndex
        while let path = nextNulDelimitedField(from: data, index: &index) {
            visit(path)
        }
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

    private func nextNulDelimitedField(
        from data: Data,
        index: inout Data.Index
    ) -> String? {
        while index < data.endIndex {
            let fieldStart = index
            while index < data.endIndex, data[index] != 0 {
                data.formIndex(after: &index)
            }
            let fieldEnd = index
            if index < data.endIndex {
                data.formIndex(after: &index)
            }
            if fieldStart != fieldEnd {
                return String(decoding: data[fieldStart..<fieldEnd], as: UTF8.self)
            }
        }
        return nil
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
