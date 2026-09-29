/// A file row in the results outline. Reference identity is the outline
/// item identity, so a file keeps its row, selection and expansion while
/// matches stream in.
public final class FileSearchFileNode {
    public let path: String
    public let relativePath: String
    public private(set) var matches: [FileSearchMatch]
    /// The user's collapse choice. New files start expanded.
    public var isExpanded = true
    private var matchNodes: [FileSearchMatchNode?]

    init(path: String, relativePath: String, matches: [FileSearchMatch]) {
        self.path = path
        self.relativePath = relativePath
        self.matches = matches
        self.matchNodes = Array(repeating: nil, count: matches.count)
    }

    /// The row object for one match, created on first request so a collapsed
    /// file with many matches allocates nothing per match.
    public func matchNode(at index: Int) -> FileSearchMatchNode {
        if let node = matchNodes[index] { return node }
        let node = FileSearchMatchNode(file: self, index: index)
        matchNodes[index] = node
        return node
    }

    func append(_ newMatches: [FileSearchMatch]) {
        matches += newMatches
        matchNodes += Array(repeating: nil, count: newMatches.count)
    }
}

/// A match row. `file` is unowned-safe because the tree owns every file node
/// for as long as the outline can ask for its children.
public final class FileSearchMatchNode {
    public unowned let file: FileSearchFileNode
    public let index: Int

    init(file: FileSearchFileNode, index: Int) {
        self.file = file
        self.index = index
    }

    public var match: FileSearchMatch { file.matches[index] }
}

/// What one batch changed, in the order an outline must apply it: first the
/// grown existing files, then the appended files.
public struct FileSearchTreeChange: Equatable, Sendable {
    /// Existing files that gained matches, with their previous match counts.
    public var grownFiles: [(fileIndex: Int, previousCount: Int)]
    /// Newly appended files.
    public var insertedFiles: Range<Int>

    public var isEmpty: Bool { grownFiles.isEmpty && insertedFiles.isEmpty }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.insertedFiles == rhs.insertedFiles &&
            lhs.grownFiles.map(\.fileIndex) == rhs.grownFiles.map(\.fileIndex) &&
            lhs.grownFiles.map(\.previousCount) == rhs.grownFiles.map(\.previousCount)
    }
}

/// A position in results order, used by next/previous navigation.
public struct FileSearchResultPosition: Hashable, Sendable {
    public let fileIndex: Int
    /// `nil` for the file row itself.
    public let matchIndex: Int?

    public init(fileIndex: Int, matchIndex: Int?) {
        self.fileIndex = fileIndex
        self.matchIndex = matchIndex
    }
}

/// Search results grouped by file, in first-seen order.
public final class FileSearchResultTree {
    public private(set) var files: [FileSearchFileNode] = []
    public private(set) var matchCount = 0
    private var fileIndexByPath: [String: Int] = [:]
    private let relativePath: (String) -> String

    /// `relativePath` maps an absolute match path to the path shown in the row.
    public init(relativePath: @escaping (String) -> String) {
        self.relativePath = relativePath
    }

    public var fileCount: Int { files.count }
    public var isEmpty: Bool { files.isEmpty }

    public func removeAll() {
        files.removeAll()
        fileIndexByPath.removeAll()
        matchCount = 0
    }

    /// Merges a batch. Matches for a file already listed join that file even
    /// when ripgrep reports it again later.
    @discardableResult
    public func apply(_ batch: [FileSearchFileMatches]) -> FileSearchTreeChange {
        let firstNewIndex = files.count
        var grown: [Int: Int] = [:]
        for group in batch where !group.matches.isEmpty {
            matchCount += group.matches.count
            if let index = fileIndexByPath[group.path] {
                if index < firstNewIndex, grown[index] == nil {
                    grown[index] = files[index].matches.count
                }
                files[index].append(group.matches)
            } else {
                fileIndexByPath[group.path] = files.count
                files.append(FileSearchFileNode(
                    path: group.path,
                    relativePath: relativePath(group.path),
                    matches: group.matches
                ))
            }
        }
        return FileSearchTreeChange(
            grownFiles: grown.sorted { $0.key < $1.key }.map { (fileIndex: $0.key, previousCount: $0.value) },
            insertedFiles: firstNewIndex..<files.count
        )
    }

    /// Removes one file and its matches (VS Code's Dismiss).
    @discardableResult
    public func remove(_ file: FileSearchFileNode) -> Bool {
        guard let index = index(of: file) else { return false }
        files.remove(at: index)
        matchCount -= file.matches.count
        fileIndexByPath.removeValue(forKey: file.path)
        for later in index..<files.count {
            fileIndexByPath[files[later].path] = later
        }
        return true
    }

    public func index(of file: FileSearchFileNode) -> Int? {
        guard let index = fileIndexByPath[file.path], files[index] === file else { return nil }
        return index
    }

    public func position(of node: FileSearchMatchNode) -> FileSearchResultPosition? {
        guard let fileIndex = index(of: node.file) else { return nil }
        return FileSearchResultPosition(fileIndex: fileIndex, matchIndex: node.index)
    }

    /// The first match after `position` in results order, wrapping around.
    /// From a file row, that file's first match is next.
    public func nextMatch(after position: FileSearchResultPosition?) -> FileSearchResultPosition? {
        guard matchCount > 0 else { return nil }
        var fileIndex = position?.fileIndex ?? 0
        var matchIndex = position.map { ($0.matchIndex ?? -1) + 1 } ?? 0
        for _ in 0...files.count {
            if fileIndex < files.count, matchIndex < files[fileIndex].matches.count {
                return FileSearchResultPosition(fileIndex: fileIndex, matchIndex: matchIndex)
            }
            fileIndex = (fileIndex + 1) % files.count
            matchIndex = 0
        }
        return nil
    }

    /// The last match before `position` in results order, wrapping around.
    /// From a file row, the previous file's last match is previous.
    public func previousMatch(before position: FileSearchResultPosition?) -> FileSearchResultPosition? {
        guard matchCount > 0 else { return nil }
        var fileIndex = position?.fileIndex ?? 0
        var matchIndex = (position?.matchIndex ?? 0) - 1
        for _ in 0...files.count {
            if fileIndex < files.count, matchIndex >= 0, matchIndex < files[fileIndex].matches.count {
                return FileSearchResultPosition(fileIndex: fileIndex, matchIndex: matchIndex)
            }
            fileIndex = (fileIndex - 1 + files.count) % files.count
            matchIndex = files[fileIndex].matches.count - 1
        }
        return nil
    }
}
