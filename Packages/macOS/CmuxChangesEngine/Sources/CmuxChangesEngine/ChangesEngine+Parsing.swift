import Foundation

extension ChangesEngine {
    func parseUntrackedPaths(_ output: String) -> [String] {
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var paths: [String] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            guard entry.count >= 3 else {
                index += 1
                continue
            }
            let status = String(entry.prefix(2))
            if status == "??" {
                paths.append(String(entry.dropFirst(3)))
            }
            index += 1
            if status.contains("R") || status.contains("C") {
                index += 1
            }
        }
        return paths
    }

    func parseTrackedChanges(_ output: String) throws -> [TrackedChange] {
        let tokens = output.components(separatedBy: "\0")
        var rawChanges: [RawGitChange] = []
        var index = 0

        while index < tokens.count, tokens[index].hasPrefix(":") {
            let metadata = tokens[index]
            guard let statusToken = metadata.split(separator: " ").last,
                  let statusCode = statusToken.first else {
                throw ChangesEngineError.gitFailed("malformed raw diff metadata")
            }
            index += 1
            guard index < tokens.count else {
                throw ChangesEngineError.gitFailed("raw diff path is missing")
            }
            let firstPath = tokens[index]
            index += 1
            let status = fileStatus(rawCode: statusCode)
            if statusCode == "R" || statusCode == "C" {
                guard index < tokens.count else {
                    throw ChangesEngineError.gitFailed("rename destination is missing")
                }
                rawChanges.append(RawGitChange(
                    path: tokens[index],
                    oldPath: firstPath,
                    status: status
                ))
                index += 1
            } else {
                rawChanges.append(RawGitChange(path: firstPath, oldPath: nil, status: status))
            }
        }

        let rawByPath = Dictionary(uniqueKeysWithValues: rawChanges.map { ($0.path, $0) })
        var changes: [TrackedChange] = []
        while index < tokens.count {
            let header = tokens[index]
            index += 1
            if header.isEmpty { continue }
            let fields = header.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                throw ChangesEngineError.gitFailed("malformed numstat record")
            }
            let isBinary = fields[0] == "-" || fields[1] == "-"
            let additions = isBinary ? 0 : (Int(fields[0]) ?? 0)
            let deletions = isBinary ? 0 : (Int(fields[1]) ?? 0)

            let path: String
            let oldPath: String?
            if fields[2].isEmpty {
                guard index + 1 < tokens.count else {
                    throw ChangesEngineError.gitFailed("numstat rename paths are missing")
                }
                oldPath = tokens[index]
                path = tokens[index + 1]
                index += 2
            } else {
                path = String(fields[2])
                oldPath = nil
            }
            let raw = rawByPath[path]
            changes.append(TrackedChange(
                path: path,
                oldPath: raw?.oldPath ?? oldPath,
                status: raw?.status ?? .modified,
                additions: additions,
                deletions: deletions,
                isBinary: isBinary
            ))
        }
        return changes
    }

    func splitPatchSections(_ patch: String) -> [String] {
        guard let first = patch.range(of: "diff --git ")?.lowerBound else { return [] }
        var starts = [first]
        var searchStart = patch.index(first, offsetBy: "diff --git ".count)
        while let boundary = patch.range(of: "\ndiff --git ", range: searchStart..<patch.endIndex) {
            let start = patch.index(after: boundary.lowerBound)
            starts.append(start)
            searchStart = boundary.upperBound
        }
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : patch.endIndex
            return String(patch[start..<end])
        }
    }

    func parseUnifiedDiff(_ patch: String) throws -> [DiffHunk] {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var hunks: [DiffHunk] = []
        var header: (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, section: String?)?
        var rows: [DiffRow] = []
        var oldNumber = 0
        var newNumber = 0

        for line in lines {
            if line.hasPrefix("@@ ") {
                if let header {
                    hunks.append(DiffHunk(
                        oldStart: header.oldStart,
                        oldLines: header.oldLines,
                        newStart: header.newStart,
                        newLines: header.newLines,
                        sectionHeading: header.section,
                        rows: rows
                    ))
                }
                header = try parseHunkHeader(line)
                rows = []
                oldNumber = header?.oldStart ?? 0
                newNumber = header?.newStart ?? 0
                continue
            }
            guard header != nil else { continue }
            if line.hasPrefix("\\ No newline at end of file") {
                rows.append(DiffRow(
                    kind: .noNewline,
                    oldNo: nil,
                    newNo: nil,
                    text: "No newline at end of file"
                ))
            } else if line.hasPrefix("+") {
                rows.append(DiffRow(kind: .add, oldNo: nil, newNo: newNumber, text: String(line.dropFirst())))
                newNumber += 1
            } else if line.hasPrefix("-") {
                rows.append(DiffRow(kind: .del, oldNo: oldNumber, newNo: nil, text: String(line.dropFirst())))
                oldNumber += 1
            } else if line.hasPrefix(" ") {
                rows.append(DiffRow(
                    kind: .context,
                    oldNo: oldNumber,
                    newNo: newNumber,
                    text: String(line.dropFirst())
                ))
                oldNumber += 1
                newNumber += 1
            }
        }
        if let header {
            hunks.append(DiffHunk(
                oldStart: header.oldStart,
                oldLines: header.oldLines,
                newStart: header.newStart,
                newLines: header.newLines,
                sectionHeading: header.section,
                rows: rows
            ))
        }
        return hunks
    }

    func pagedHunks(_ hunks: [DiffHunk], cursor: String?) throws -> (hunks: [DiffHunk], next: String?) {
        let totalRows = hunks.reduce(0) { $0 + $1.rows.count }
        let offset: Int
        if let cursor {
            guard let parsed = Int(cursor), parsed >= 0, parsed <= totalRows else {
                throw ChangesEngineError.invalidCursor(cursor)
            }
            offset = parsed
        } else {
            offset = 0
        }
        let pageEnd = min(offset + Self.pageRowLimit, totalRows)
        var result: [DiffHunk] = []
        var hunkStart = 0
        for hunk in hunks {
            let hunkEnd = hunkStart + hunk.rows.count
            let lower = max(offset, hunkStart)
            let upper = min(pageEnd, hunkEnd)
            if lower < upper {
                let localLower = lower - hunkStart
                let localUpper = upper - hunkStart
                result.append(DiffHunk(
                    oldStart: hunk.oldStart,
                    oldLines: hunk.oldLines,
                    newStart: hunk.newStart,
                    newLines: hunk.newLines,
                    sectionHeading: hunk.sectionHeading,
                    rows: Array(hunk.rows[localLower..<localUpper])
                ))
            }
            hunkStart = hunkEnd
        }
        return (result, pageEnd < totalRows ? String(pageEnd) : nil)
    }

    private func fileStatus(rawCode: Character) -> ChangesFileStatus {
        switch rawCode {
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        default: .modified
        }
    }

    private func parseHunkHeader(
        _ line: String
    ) throws -> (oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, section: String?) {
        let rangeStart = line.index(line.startIndex, offsetBy: 3)
        guard let closing = line.range(of: " @@", range: rangeStart..<line.endIndex) else {
            throw ChangesEngineError.gitFailed("malformed hunk header")
        }
        let ranges = line[rangeStart..<closing.lowerBound].split(separator: " ")
        guard ranges.count == 2,
              let oldRange = parseHunkRange(String(ranges[0]), prefix: "-"),
              let newRange = parseHunkRange(String(ranges[1]), prefix: "+") else {
            throw ChangesEngineError.gitFailed("malformed hunk ranges")
        }
        let rawSection = line[closing.upperBound...].trimmingCharacters(in: .whitespaces)
        return (oldRange.start, oldRange.count, newRange.start, newRange.count, rawSection.isEmpty ? nil : rawSection)
    }

    private func parseHunkRange(_ value: String, prefix: Character) -> (start: Int, count: Int)? {
        guard value.first == prefix else { return nil }
        let components = value.dropFirst().split(separator: ",", maxSplits: 1)
        guard let start = Int(components[0]) else { return nil }
        let count = components.count == 2 ? Int(components[1]) : 1
        guard let count else { return nil }
        return (start, count)
    }
}
