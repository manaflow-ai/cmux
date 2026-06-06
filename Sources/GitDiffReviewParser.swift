import Foundation

nonisolated enum GitDiffReviewParser {
    private struct StatusEntry: Equatable {
        let status: GitDiffReviewFileStatus
        let oldPath: String?
    }

    static func parse(diffText: String, statusText: String) -> [GitDiffReviewFile] {
        let statusEntries = parseStatusEntries(statusText)
        var files: [GitDiffReviewFile] = []

        var currentPath: String?
        var currentOldPath: String?
        var currentStatus: GitDiffReviewFileStatus = .modified
        var currentHunks: [GitDiffReviewHunk] = []
        var currentHunkHeader: String?
        var currentHunkOldStart = 0
        var currentHunkNewStart = 0
        var currentLines: [GitDiffReviewLine] = []
        var oldLineNumber = 0
        var newLineNumber = 0
        var additions = 0
        var deletions = 0

        func flushHunk() {
            guard let header = currentHunkHeader else { return }
            currentHunks.append(
                GitDiffReviewHunk(
                    header: header,
                    oldStart: currentHunkOldStart,
                    newStart: currentHunkNewStart,
                    lines: currentLines
                )
            )
            currentHunkHeader = nil
            currentLines.removeAll(keepingCapacity: true)
        }

        func flushFile() {
            guard let path = currentPath else { return }
            flushHunk()
            let statusEntry = statusEntries[path]
            let status = statusEntry?.status ?? currentStatus
            let oldPath = oldPathForStatus(status, statusEntry: statusEntry, diffOldPath: currentOldPath)
            files.append(
                GitDiffReviewFile(
                    path: path,
                    oldPath: oldPath,
                    status: status,
                    additions: additions,
                    deletions: deletions,
                    hunks: currentHunks
                )
            )
            currentPath = nil
            currentOldPath = nil
            currentStatus = .modified
            currentHunks.removeAll(keepingCapacity: true)
            currentLines.removeAll(keepingCapacity: true)
            currentHunkHeader = nil
            additions = 0
            deletions = 0
        }

        let diffLines = diffText.components(separatedBy: "\n")
        for (rawLineIndex, rawLine) in diffLines.enumerated() {
            if rawLineIndex == diffLines.count - 1, rawLine.isEmpty {
                continue
            }
            let line = rawLine.removingTrailingCarriageReturn()

            if line.hasPrefix("diff --git ") {
                flushFile()
                let paths = parseDiffGitPaths(line)
                currentOldPath = paths.oldPath
                currentPath = paths.newPath
                currentStatus = statusEntries[paths.newPath]?.status ?? .modified
                continue
            }

            guard currentPath != nil else { continue }

            if line.hasPrefix("new file mode") {
                currentStatus = .added
                continue
            }
            if line.hasPrefix("deleted file mode") {
                currentStatus = .deleted
                continue
            }
            if line.hasPrefix("similarity index") {
                continue
            }
            if line.hasPrefix("copy from ") {
                currentOldPath = String(line.dropFirst("copy from ".count))
                currentStatus = .copied
                continue
            }
            if line.hasPrefix("copy to ") {
                currentPath = String(line.dropFirst("copy to ".count))
                currentStatus = .copied
                continue
            }
            if line.hasPrefix("rename from ") {
                currentOldPath = String(line.dropFirst("rename from ".count))
                currentStatus = .renamed
                continue
            }
            if line.hasPrefix("rename to ") {
                currentPath = String(line.dropFirst("rename to ".count))
                currentStatus = .renamed
                continue
            }
            if currentHunkHeader == nil, line.hasPrefix("--- ") {
                if let path = parseDiffFileMarkerPath(String(line.dropFirst("--- ".count))) {
                    currentOldPath = path
                }
                continue
            }
            if currentHunkHeader == nil, line.hasPrefix("+++ ") {
                if let path = parseDiffFileMarkerPath(String(line.dropFirst("+++ ".count))) {
                    currentPath = path
                    currentStatus = statusEntries[path]?.status ?? currentStatus
                }
                continue
            }
            if line.hasPrefix("@@ ") {
                flushHunk()
                let starts = parseHunkStarts(line)
                currentHunkHeader = line
                currentHunkOldStart = starts.oldStart
                currentHunkNewStart = starts.newStart
                oldLineNumber = starts.oldStart
                newLineNumber = starts.newStart
                continue
            }

            guard currentHunkHeader != nil else { continue }

            if line.hasPrefix("+") {
                currentLines.append(
                    GitDiffReviewLine(
                        kind: .addition,
                        oldLineNumber: nil,
                        newLineNumber: newLineNumber,
                        content: String(line.dropFirst())
                    )
                )
                newLineNumber += 1
                additions += 1
            } else if line.hasPrefix("-") {
                currentLines.append(
                    GitDiffReviewLine(
                        kind: .deletion,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: nil,
                        content: String(line.dropFirst())
                    )
                )
                oldLineNumber += 1
                deletions += 1
            } else if line.hasPrefix("\\") {
                currentLines.append(
                    GitDiffReviewLine(
                        kind: .note,
                        oldLineNumber: nil,
                        newLineNumber: nil,
                        content: String(line.dropFirst())
                    )
                )
            } else {
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                currentLines.append(
                    GitDiffReviewLine(
                        kind: .context,
                        oldLineNumber: oldLineNumber,
                        newLineNumber: newLineNumber,
                        content: content
                    )
                )
                oldLineNumber += 1
                newLineNumber += 1
            }
        }

        flushFile()

        let existingPaths = Set(files.map(\.path))
        let statusOnlyFiles = statusEntries
            .filter { !existingPaths.contains($0.key) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { path, entry in
                GitDiffReviewFile(
                    path: path,
                    oldPath: entry.oldPath,
                    status: entry.status,
                    additions: 0,
                    deletions: 0,
                    hunks: []
                )
            }
        return files + statusOnlyFiles
    }

    private static func parseStatusEntries(_ statusText: String) -> [String: StatusEntry] {
        var entries: [String: StatusEntry] = [:]
        let tokens = statusText.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            guard token.count >= 4 else {
                index += 1
                continue
            }

            let statusCode = String(token.prefix(2))
            let path = String(token.dropFirst(3))
            let status = statusFromPorcelain(statusCode)
            var oldPath: String?

            if status == .renamed || status == .copied {
                let nextIndex = index + 1
                if nextIndex < tokens.count {
                    oldPath = tokens[nextIndex]
                    index += 1
                }
            }

            entries[path] = StatusEntry(status: status, oldPath: oldPath)
            index += 1
        }

        return entries
    }

    private static func statusFromPorcelain(_ code: String) -> GitDiffReviewFileStatus {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCode == "??" {
            return .untracked
        }
        let unmergedCodes: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        if unmergedCodes.contains(trimmedCode) {
            return .unmerged
        }
        if code.contains("R") {
            return .renamed
        }
        if code.contains("C") {
            return .copied
        }
        if code.contains("A") {
            return .added
        }
        if code.contains("D") {
            return .deleted
        }
        if code.contains("T") {
            return .typeChanged
        }
        if code.contains("M") {
            return .modified
        }
        return .unknown(trimmedCode)
    }

    private static func oldPathForStatus(
        _ status: GitDiffReviewFileStatus,
        statusEntry: StatusEntry?,
        diffOldPath: String?
    ) -> String? {
        switch status {
        case .renamed, .copied:
            return statusEntry?.oldPath ?? diffOldPath
        case .modified, .added, .deleted, .untracked, .unmerged, .typeChanged, .unknown:
            return nil
        }
    }

    private static func parseDiffGitPaths(_ line: String) -> (oldPath: String?, newPath: String) {
        let body = String(line.dropFirst("diff --git ".count))
        let tokens = parseDiffHeaderPathTokens(body)

        guard tokens.count >= 2 else {
            return (nil, stripDiffPathPrefix(tokens.first ?? body))
        }

        return (
            oldPath: stripDiffPathPrefix(tokens[0]),
            newPath: stripDiffPathPrefix(tokens[1])
        )
    }

    private static func parseDiffHeaderPathTokens(_ body: String) -> [String] {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.first == "\"" {
            return parseQuotedDiffHeaderPathTokens(trimmed)
        }

        return parseUnquotedDiffHeaderPathTokens(trimmed)
    }

    private static func parseQuotedDiffHeaderPathTokens(_ body: String) -> [String] {
        var tokens: [String] = []
        var index = body.startIndex

        while index < body.endIndex, tokens.count < 2 {
            while index < body.endIndex, body[index] == " " {
                index = body.index(after: index)
            }
            guard index < body.endIndex else { break }

            if body[index] == "\"" {
                let parsed = parseQuotedPathToken(body, startingAt: body.index(after: index))
                tokens.append(parsed.token)
                index = parsed.nextIndex
            } else {
                tokens.append(String(body[index..<body.endIndex]))
                break
            }
        }

        return tokens
    }

    private static func parseUnquotedDiffHeaderPathTokens(_ body: String) -> [String] {
        let candidates = diffHeaderPathBoundaryCandidates(in: body)
        if let exactMatch = candidates.first(where: { stripDiffPathPrefix($0.oldPath) == stripDiffPathPrefix($0.newPath) }) {
            return [exactMatch.oldPath, exactMatch.newPath]
        }
        if let firstCandidate = candidates.first {
            return [firstCandidate.oldPath, firstCandidate.newPath]
        }
        return [body]
    }

    private static func diffHeaderPathBoundaryCandidates(in body: String) -> [(oldPath: String, newPath: String)] {
        var candidates: [(oldPath: String, newPath: String)] = []
        var searchRange = body.startIndex..<body.endIndex

        while let boundary = body.range(of: " b/", range: searchRange) {
            let oldPath = String(body[..<boundary.lowerBound])
            let newPathStart = body.index(after: boundary.lowerBound)
            let newPath = String(body[newPathStart..<body.endIndex])
            candidates.append((oldPath: oldPath, newPath: newPath))
            searchRange = body.index(after: boundary.lowerBound)..<body.endIndex
        }

        return candidates
    }

    private static func parseDiffFileMarkerPath(_ marker: String) -> String? {
        let pathText: String
        if let tabIndex = marker.firstIndex(of: "\t") {
            pathText = String(marker[..<tabIndex])
        } else {
            pathText = marker
        }

        guard pathText != "/dev/null" else { return nil }

        if pathText.first == "\"" {
            let parsed = parseQuotedPathToken(pathText, startingAt: pathText.index(after: pathText.startIndex))
            return stripDiffPathPrefix(parsed.token)
        }

        return stripDiffPathPrefix(pathText)
    }

    private static func parseQuotedPathToken(_ body: String, startingAt start: String.Index) -> (token: String, nextIndex: String.Index) {
        var bytes: [UInt8] = []
        var index = start

        while index < body.endIndex {
            let character = body[index]
            index = body.index(after: index)

            if character == "\"" {
                return (decodeQuotedPathBytes(bytes), index)
            }

            if character == "\\", index < body.endIndex {
                let parsed = parseQuotedEscape(body, startingAt: index)
                bytes.append(contentsOf: parsed.bytes)
                index = parsed.nextIndex
            } else {
                bytes.append(contentsOf: String(character).utf8)
            }
        }

        return (decodeQuotedPathBytes(bytes), index)
    }

    private static func parseQuotedEscape(_ body: String, startingAt start: String.Index) -> (bytes: [UInt8], nextIndex: String.Index) {
        let escaped = body[start]
        let nextIndex = body.index(after: start)

        switch escaped {
        case "n": return (Array("\n".utf8), nextIndex)
        case "r": return (Array("\r".utf8), nextIndex)
        case "t": return (Array("\t".utf8), nextIndex)
        case "\"": return (Array("\"".utf8), nextIndex)
        case "\\": return (Array("\\".utf8), nextIndex)
        default:
            if let scalar = escaped.unicodeScalars.first,
               scalar.value >= 48,
               scalar.value <= 55 {
                return parseOctalEscape(body, startingAt: start)
            }
            return (Array(String(escaped).utf8), nextIndex)
        }
    }

    private static func parseOctalEscape(_ body: String, startingAt start: String.Index) -> (bytes: [UInt8], nextIndex: String.Index) {
        var digits = ""
        var index = start

        while index < body.endIndex,
              digits.count < 3,
              let scalar = body[index].unicodeScalars.first,
              scalar.value >= 48,
              scalar.value <= 55 {
            digits.append(body[index])
            index = body.index(after: index)
        }

        guard let value = UInt32(digits, radix: 8),
              value <= UInt8.max else {
            return (Array(String(body[start]).utf8), body.index(after: start))
        }

        return ([UInt8(value)], index)
    }

    private static func decodeQuotedPathBytes(_ bytes: [UInt8]) -> String {
        if let decoded = String(data: Data(bytes), encoding: .utf8) {
            return decoded
        }

        return bytes.reduce(into: "") { result, byte in
            if let scalar = UnicodeScalar(UInt32(byte)) {
                result.unicodeScalars.append(scalar)
            }
        }
    }

    private static func stripDiffPathPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }

    private static func parseHunkStarts(_ header: String) -> (oldStart: Int, newStart: Int) {
        let parts = header.split(separator: " ")
        guard parts.count >= 3 else { return (0, 0) }
        return (
            oldStart: parseRangeStart(String(parts[1])),
            newStart: parseRangeStart(String(parts[2]))
        )
    }

    private static func parseRangeStart(_ range: String) -> Int {
        var trimmed = range
        if trimmed.hasPrefix("-") || trimmed.hasPrefix("+") {
            trimmed.removeFirst()
        }
        let start = trimmed.split(separator: ",", maxSplits: 1).first.map(String.init) ?? trimmed
        return Int(start) ?? 0
    }
}

private extension String {
    func removingTrailingCarriageReturn() -> String {
        guard hasSuffix("\r") else { return self }
        return String(dropLast())
    }
}
