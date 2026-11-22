import Foundation
import Synchronization

/// One changed file. Built from full texts (ACP `{type:"diff", path, oldText, newText}`),
/// which allows expanding hidden context, or parsed from a unified diff.
public struct DiffFile: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case modified = "M", added = "A", deleted = "D", renamed = "R"
    }

    public var id: String { path }
    public var path: String
    public var oldPath: String?
    public var status: Status { didSet { summarize() } }
    /// Every line of the file in diff order (context, deletions, additions). For a
    /// parsed unified diff, only the lines inside hunks, with `gaps` between them.
    public var lines: [DiffLine] { didSet { summarize() } }
    /// True when `lines` covers the whole file (context can be expanded freely).
    public var hasFullContext: Bool
    /// Added and removed line counts, counted once per content (rows and headers read them every body).
    public private(set) var additions = 0
    public private(set) var deletions = 0
    /// FNV-1a over the status and the lines' kinds and texts: the viewed mark's fingerprint
    /// (`DiffViewedStore.key`), hashed once per content instead of per lookup.
    public private(set) var contentHash: UInt64 = 0

    public init(path: String, oldPath: String? = nil, status: Status, lines: [DiffLine], hasFullContext: Bool) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.lines = lines
        self.hasFullContext = hasFullContext
        summarize()
    }

    private mutating func summarize() {
        var additions = 0
        var deletions = 0
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            hash ^= 0x0A
            hash = hash &* 0x0000_0100_0000_01B3
        }
        mix(status.rawValue)
        for line in lines {
            switch line.kind {
            case .added: additions += 1
            case .removed: deletions += 1
            case .context: break
            }
            mix(line.kind.fingerprintName)
            mix(line.text)
        }
        self.additions = additions
        self.deletions = deletions
        contentHash = hash
    }

    /// Builds a file diff from the old and new contents (nil old text = new file).
    public init(path: String, oldText: String?, newText: String?) {
        let old = oldText.map(Self.splitLines) ?? []
        let new = newText.map(Self.splitLines) ?? []
        let status: Status = oldText == nil ? .added : (newText == nil ? .deleted : .modified)
        self.init(path: path, status: status, lines: LineDiff(old: old, new: new).lines(), hasFullContext: true)
    }

    /// One file's agent edits in order. An edit with no old text is the whole file (a
    /// write); an edit with old text is a snippet replaced in place (Claude's Edit sends only
    /// `old_string` and `new_string`). From a whole file, later edits are applied to it, so the
    /// diff is the file as created. From snippets, each edit is its own hunk with no line
    /// numbers (where it sits in the file is unknown), as the Mac's Last turn view keeps each
    /// edit separate; merging the first snippet's old text with the last one's new text
    /// compared two different snippets.
    public init(path: String, edits: [(oldText: String?, newText: String)]) {
        // A turn's change set is rebuilt from its edits whenever a view asks for it: the line
        // diff (Myers plus word diffs) runs once per distinct edit list, not once per ask.
        let key = EditsKey(path: path, edits: edits.map { EditsKey.Edit(oldText: $0.oldText, newText: $0.newText) })
        if let cached = Self.editsCache.withLock({ $0[key] }) {
            self = cached
            return
        }
        self.init(uncachedPath: path, edits: edits)
        let made = self
        Self.editsCache.withLock { cache in
            if cache.count >= Self.editsCacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = made
        }
    }

    struct EditsKey: Hashable, Sendable {
        struct Edit: Hashable, Sendable {
            var oldText: String?
            var newText: String
        }

        var path: String
        var edits: [Edit]
    }

    static let editsCacheLimit = 64
    private static let editsCache = Mutex<[EditsKey: DiffFile]>([:])
    /// Line diffs computed per path (the memoization tests read it; DEBUG only).
    #if DEBUG
    static let editsDiffCounts = Mutex<[String: Int]>([:])
    #endif

    private init(uncachedPath path: String, edits: [(oldText: String?, newText: String)]) {
        #if DEBUG
        Self.editsDiffCounts.withLock { $0[path, default: 0] += 1 }
        #endif
        guard let first = edits.first else {
            self.init(path: path, status: .modified, lines: [], hasFullContext: false)
            return
        }
        if first.oldText == nil {
            var text = first.newText
            var applied = true
            for edit in edits.dropFirst() {
                guard let old = edit.oldText else { text = edit.newText; continue }
                guard !old.isEmpty, let range = text.range(of: old) else { applied = false; break }
                text.replaceSubrange(range, with: edit.newText)
            }
            if applied {
                self.init(path: path, oldText: nil, newText: text)
                return
            }
        }
        var lines: [DiffLine] = []
        for (index, edit) in edits.enumerated() {
            if index > 0 { lines.append(DiffLine(kind: .context, oldNumber: nil, newNumber: nil, text: "", isGap: true)) }
            let old = edit.oldText.map(Self.splitLines) ?? []
            lines += LineDiff(old: old, new: Self.splitLines(edit.newText)).lines().map { line in
                var line = line
                line.oldNumber = nil
                line.newNumber = nil
                return line
            }
        }
        self.init(path: path, status: first.oldText == nil ? .added : .modified, lines: lines, hasFullContext: false)
    }

    static func splitLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    public var fileName: String { (path as NSString).lastPathComponent }
    public var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }

    /// Hunks with `context` lines around each change (GitHub default 3). O(lines): the ranges
    /// and each header's declaration come from one forward pass (a backward search per hunk
    /// was O(hunks x lines) and stalled the transcript on a long rewrite).
    public func hunks(context: Int = 3) -> [DiffHunk] {
        let ranges = DiffRows.changeRanges(lines, context: context)
        guard !ranges.isEmpty else { return [] }
        var hunks: [DiffHunk] = []
        hunks.reserveCapacity(ranges.count)
        var declaration: String?
        var scanned = 0
        for range in ranges {
            // The nearest declaration strictly above the hunk.
            while scanned < range.lowerBound {
                let trimmed = lines[scanned].text.trimmingCharacters(in: .whitespaces)
                if DiffHunk.isDeclaration(trimmed) { declaration = trimmed }
                scanned += 1
            }
            hunks.append(DiffHunk(file: self, range: range, declaration: declaration))
        }
        return hunks
    }

    /// The first `count` lines of the change as unified text (transcript snippets).
    public func unifiedPreview(maxLines: Int = 12) -> (lines: [DiffLine], remaining: Int) {
        // The ranges only (no headers), counted without copying the lines past the preview.
        var preview: [DiffLine] = []
        var total = 0
        for range in DiffRows.changeRanges(lines, context: 1) {
            total += range.count
            if preview.count < maxLines { preview += lines[range].prefix(maxLines - preview.count) }
        }
        return (preview, max(0, total - maxLines))
    }
}

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case context, added, removed

        /// The name as the viewed fingerprint has always hashed it (`"\(kind)"`), without the interpolation.
        var fingerprintName: String {
            switch self {
            case .context: "context"
            case .added: "added"
            case .removed: "removed"
            }
        }
    }

    public var kind: Kind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String
    /// Character ranges that changed inside this line (word-level highlight).
    public var changedRanges: [Range<Int>]
    /// A placeholder for lines outside a parsed hunk (unified diff input).
    public var isGap: Bool

    public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String, changedRanges: [Range<Int>] = [], isGap: Bool = false) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
        self.changedRanges = changedRanges
        self.isGap = isGap
    }

    public var marker: String {
        switch kind {
        case .context: " "
        case .added: "+"
        case .removed: "−"
        }
    }
}

public struct DiffHunk: Identifiable, Hashable, Sendable {
    public var id: Int { range.lowerBound }
    public var range: ClosedRange<Int>
    public var header: String

    init(file: DiffFile, range: ClosedRange<Int>, declaration: String?) {
        self.range = range
        header = DiffRows.headerText(file.lines[range], declaration: declaration)
    }
}

extension DiffHunk {
    static let declarationKeywords = ["func ", "def ", "fn ", "class ", "struct ", "function ", "impl ", "extension ", "enum "]

    /// A line (trimmed) that reads as a declaration: a hunk header's function context.
    static let spacedDeclarationKeywords = declarationKeywords.map { " " + $0 }

    static func isDeclaration(_ trimmed: String) -> Bool {
        declarationKeywords.contains { trimmed.hasPrefix($0) } || spacedDeclarationKeywords.contains { trimmed.contains($0) }
    }
}

/// Line diff via Swift's Myers `difference(from:)`, with deletions ordered
/// before additions inside each change block and word-level ranges for paired lines.
struct LineDiff {
    let old: [String]
    let new: [String]

    func lines() -> [DiffLine] {
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [DiffLine] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) || (j >= new.count) {
                // Collect the full change block: removals then insertions.
                var dels: [DiffLine] = []
                while i < old.count, removed.contains(i) || j >= new.count {
                    dels.append(DiffLine(kind: .removed, oldNumber: i + 1, newNumber: nil, text: old[i]))
                    i += 1
                }
                var adds: [DiffLine] = []
                while j < new.count, inserted.contains(j) {
                    adds.append(DiffLine(kind: .added, oldNumber: nil, newNumber: j + 1, text: new[j]))
                    j += 1
                }
                WordDiff.mark(&dels, &adds)
                result += dels + adds
            } else if j < new.count, inserted.contains(j) || i >= old.count {
                var adds: [DiffLine] = []
                while j < new.count, inserted.contains(j) || i >= old.count {
                    adds.append(DiffLine(kind: .added, oldNumber: nil, newNumber: j + 1, text: new[j]))
                    j += 1
                }
                result += adds
            } else {
                result.append(DiffLine(kind: .context, oldNumber: i + 1, newNumber: j + 1, text: new[j]))
                i += 1
                j += 1
            }
        }
        return result
    }
}

/// Word-level highlight: pairs the i-th removed line with the i-th added line
/// and marks the tokens that differ, when the lines are similar enough to read as an edit.
struct WordDiff {
    static func mark(_ dels: inout [DiffLine], _ adds: inout [DiffLine]) {
        for index in 0..<min(dels.count, adds.count) {
            let a = tokens(dels[index].text)
            let b = tokens(adds[index].text)
            let diff = b.map(\.text).difference(from: a.map(\.text))
            var removedTokens = Set<Int>()
            var insertedTokens = Set<Int>()
            for change in diff {
                switch change {
                case .remove(let offset, _, _): removedTokens.insert(offset)
                case .insert(let offset, _, _): insertedTokens.insert(offset)
                }
            }
            let unchanged = a.count - removedTokens.count
            // Skip word highlights when the lines share little (a rewrite, not an edit).
            guard unchanged * 2 >= max(a.count, b.count), !(removedTokens.isEmpty && insertedTokens.isEmpty) else { continue }
            dels[index].changedRanges = merge(removedTokens.sorted().map { a[$0].range })
            adds[index].changedRanges = merge(insertedTokens.sorted().map { b[$0].range })
        }
    }

    struct Token {
        let text: String
        let range: Range<Int>
    }

    static func tokens(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var start = 0
        var offset = 0
        func flush() {
            if !current.isEmpty {
                tokens.append(Token(text: current, range: start..<offset))
                current = ""
            }
        }
        for character in line {
            if character.isLetter || character.isNumber || character == "_" {
                if current.isEmpty { start = offset }
                current.append(character)
            } else {
                flush()
                tokens.append(Token(text: String(character), range: offset..<offset + 1))
            }
            offset += 1
        }
        flush()
        return tokens
    }

    static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// Parses `git diff` output into files (hunk lines only; gaps between hunks are marked).
public struct UnifiedDiffParser: Sendable {
    public init() {}

    public func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var path: String?
        var oldPath: String?
        var status = DiffFile.Status.modified
        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0
        func finish() {
            if let path {
                var dels: [DiffLine] = []
                var adds: [DiffLine] = []
                var out: [DiffLine] = []
                func flushBlock() {
                    WordDiff.mark(&dels, &adds)
                    out += dels + adds
                    dels = []
                    adds = []
                }
                for line in lines {
                    switch line.kind {
                    case .removed:
                        if !adds.isEmpty { flushBlock() }
                        dels.append(line)
                    case .added: adds.append(line)
                    case .context:
                        flushBlock()
                        out.append(line)
                    }
                }
                flushBlock()
                files.append(DiffFile(path: path, oldPath: oldPath == path ? nil : oldPath, status: status, lines: out, hasFullContext: false))
            }
            path = nil
            oldPath = nil
            status = .modified
            lines = []
        }
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git ") {
                finish()
                let parts = raw.dropFirst("diff --git ".count).components(separatedBy: " b/")
                oldPath = parts.first.map { String($0.dropFirst(2)) }
                path = parts.count > 1 ? parts[1] : oldPath
            } else if raw.hasPrefix("new file") {
                status = .added
            } else if raw.hasPrefix("deleted file") {
                status = .deleted
            } else if raw.hasPrefix("rename from") {
                status = .renamed
            } else if raw.hasPrefix("+++ ") || raw.hasPrefix("--- ") || raw.hasPrefix("index ") {
                if raw.hasPrefix("+++ b/"), path == nil { path = String(raw.dropFirst(6)) }
                continue
            } else if raw.hasPrefix("@@") {
                let numbers = raw.split(separator: " ").prefix(3)
                let oldPart = numbers.dropFirst().first?.dropFirst().split(separator: ",").first
                let newPart = numbers.dropFirst(2).first?.dropFirst().split(separator: ",").first
                if !lines.isEmpty {
                    lines.append(DiffLine(kind: .context, oldNumber: nil, newNumber: nil, text: "", isGap: true))
                }
                oldLine = Int(oldPart ?? "1") ?? 1
                newLine = Int(newPart ?? "1") ?? 1
            } else if path != nil, let first = raw.first {
                let body = String(raw.dropFirst())
                switch first {
                case "+":
                    lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newLine, text: body))
                    newLine += 1
                case "-":
                    lines.append(DiffLine(kind: .removed, oldNumber: oldLine, newNumber: nil, text: body))
                    oldLine += 1
                case " ":
                    lines.append(DiffLine(kind: .context, oldNumber: oldLine, newNumber: newLine, text: body))
                    oldLine += 1
                    newLine += 1
                default:
                    break
                }
            }
        }
        finish()
        return files
    }
}

/// A set of changed files (a turn's edits, the working tree, a PR).
public struct DiffChangeSet: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var files: [DiffFile]

    public init(id: String, title: String, subtitle: String, files: [DiffFile]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.files = files
    }

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}
