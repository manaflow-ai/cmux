import Foundation

struct TerminalTranscriptImagePathScanner: Sendable {
    struct Context: Sendable {
        var cwd: String?
        var homeDirectory: String?

        init(cwd: String? = nil, homeDirectory: String? = nil) {
            self.cwd = cwd
            self.homeDirectory = homeDirectory
        }
    }

    private static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
    private static let trailingScalars = CharacterSet(charactersIn: ".,:;)]}>")
    private static let leadingScalars = CharacterSet(charactersIn: "([<{")

    func scan(rows: [String], context: Context = Context()) -> [DetectedImagePath] {
        rows.enumerated().flatMap { rowIndex, row in
            scan(row: row, rowIndex: rowIndex, context: context)
        }
    }

    private func scan(row: String, rowIndex: Int, context: Context) -> [DetectedImagePath] {
        var matches: [DetectedImagePath] = []
        var seen = Set<String>()
        for candidate in quotedCandidates(in: row) + unquotedCandidates(in: row, context: context) {
            guard let match = resolvedCandidate(candidate, rowIndex: rowIndex, context: context),
                  seen.insert(match.resolvedPath).inserted else {
                continue
            }
            matches.append(match)
        }
        return matches
    }

    private func quotedCandidates(in row: String) -> [String] {
        let characters = Array(row)
        var candidates: [String] = []
        var index = 0
        while index < characters.count {
            let quote = characters[index]
            guard quote == "\"" || quote == "'" else {
                index += 1
                continue
            }
            let start = index + 1
            index = start
            while index < characters.count, characters[index] != quote {
                index += 1
            }
            if start < index {
                candidates.append(String(characters[start..<index]))
            }
            index += 1
        }
        return candidates
    }

    private func unquotedCandidates(in row: String, context: Context) -> [String] {
        row.split(whereSeparator: \.isWhitespace).compactMap { token in
            let string = String(token)
            if let start = absoluteOrHomeStart(in: string) {
                return String(string[start...])
            }
            guard context.cwd != nil, looksRelative(string) else { return nil }
            return string
        }
    }

    private func absoluteOrHomeStart(in token: String) -> String.Index? {
        guard !token.contains("://") else { return nil }
        var index = token.startIndex
        while index < token.endIndex {
            if token[index] == "/", isPathStartAllowed(in: token, at: index) {
                return index
            }
            if token[index] == "~",
               token.index(after: index) < token.endIndex,
               token[token.index(after: index)] == "/",
               isPathStartAllowed(in: token, at: index) {
                return index
            }
            index = token.index(after: index)
        }
        return nil
    }

    private func isPathStartAllowed(in token: String, at index: String.Index) -> Bool {
        guard index > token.startIndex else { return true }
        let previous = token[token.index(before: index)]
        return previous.unicodeScalars.allSatisfy { !CharacterSet.alphanumerics.contains($0) }
    }

    private func looksRelative(_ token: String) -> Bool {
        guard !token.hasPrefix("-"),
              !token.contains("://"),
              token.contains("/") else {
            return false
        }
        return token.unicodeScalars.first.map { !Self.leadingScalars.contains($0) } ?? false
    }

    private func resolvedCandidate(
        _ candidate: String,
        rowIndex: Int,
        context: Context
    ) -> DetectedImagePath? {
        let stripped = stripWrappers(candidate)
        guard !stripped.isEmpty,
              let ext = extensionName(in: stripped),
              Self.supportedExtensions.contains(ext.lowercased()) else {
            return nil
        }
        let resolvedPath: String
        if stripped.hasPrefix("~/") {
            guard let homeDirectory = context.homeDirectory, !homeDirectory.isEmpty else {
                resolvedPath = stripped
                return DetectedImagePath(rowIndex: rowIndex, path: stripped, resolvedPath: resolvedPath)
            }
            resolvedPath = homeDirectory + String(stripped.dropFirst())
        } else if stripped.hasPrefix("/") {
            resolvedPath = stripped
        } else {
            guard let cwd = context.cwd, !cwd.isEmpty else { return nil }
            resolvedPath = URL(fileURLWithPath: stripped, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
        }
        return DetectedImagePath(rowIndex: rowIndex, path: stripped, resolvedPath: resolvedPath)
    }

    private func stripWrappers(_ candidate: String) -> String {
        var result = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.unicodeScalars.first, Self.leadingScalars.contains(first) {
            result.removeFirst()
        }
        while let last = result.unicodeScalars.last, Self.trailingScalars.contains(last) {
            result.removeLast()
        }
        return result
    }

    private func extensionName(in path: String) -> String? {
        guard let lastSlash = path.lastIndex(of: "/") else { return nil }
        let fileNameStart = path.index(after: lastSlash)
        guard fileNameStart < path.endIndex,
              let dot = path[fileNameStart...].lastIndex(of: "."),
              dot < path.index(before: path.endIndex) else {
            return nil
        }
        return String(path[path.index(after: dot)...])
    }
}

struct DetectedImagePath: Equatable, Sendable {
    let rowIndex: Int
    let path: String
    let resolvedPath: String
}
