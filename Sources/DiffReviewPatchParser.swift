import Foundation

enum DiffReviewPatchParser {
    static func parse(_ diffOutput: String, untrackedPaths: Set<String> = []) -> [DiffReviewFile] {
        guard !diffOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var files: [DiffReviewFile] = []
        var currentFile: FileAccumulator?

        for rawLine in diffOutput.components(separatedBy: "\n") {
            guard !rawLine.isEmpty else { continue }
            if rawLine.hasPrefix("diff --git ") {
                if let file = currentFile?.build(untrackedPaths: untrackedPaths) {
                    files.append(file)
                }
                currentFile = FileAccumulator(diffHeader: rawLine)
                continue
            }

            currentFile?.append(rawLine)
        }

        if let file = currentFile?.build(untrackedPaths: untrackedPaths) {
            files.append(file)
        }

        return files
    }

    private struct FileAccumulator {
        private let diffHeader: String
        private var fileHeaderLines: [String]
        private var hunkAccumulators: [HunkAccumulator] = []
        private var currentHunk: HunkAccumulator?

        init(diffHeader: String) {
            self.diffHeader = diffHeader
            self.fileHeaderLines = [diffHeader]
        }

        mutating func append(_ line: String) {
            if line.hasPrefix("@@ ") {
                flushCurrentHunk()
                currentHunk = HunkAccumulator(header: line)
                return
            }

            if currentHunk != nil {
                currentHunk?.append(line)
            } else {
                fileHeaderLines.append(line)
            }
        }

        mutating func build(untrackedPaths: Set<String>) -> DiffReviewFile? {
            flushCurrentHunk()
            guard let pathInfo = pathInfo() else { return nil }

            let status = fileStatus(
                path: pathInfo.path,
                untrackedPaths: untrackedPaths
            )
            let hunkValues = hunkAccumulators.enumerated().map { index, accumulator in
                accumulator.build(
                    id: "\(pathInfo.path):\(index)",
                    fileHeaderLines: fileHeaderLines
                )
            }
            let added = hunkValues.reduce(0) { $0 + $1.addedLineCount }
            let deleted = hunkValues.reduce(0) { $0 + $1.deletedLineCount }

            return DiffReviewFile(
                id: pathInfo.path,
                path: pathInfo.path,
                oldPath: pathInfo.oldPath,
                status: hunkValues.isEmpty && isBinaryChange ? .binary : status,
                hunks: hunkValues,
                addedLineCount: added,
                deletedLineCount: deleted
            )
        }

        private mutating func flushCurrentHunk() {
            guard let hunk = currentHunk else { return }
            hunkAccumulators.append(hunk)
            currentHunk = nil
        }

        private var isBinaryChange: Bool {
            fileHeaderLines.contains { $0.hasPrefix("Binary files ") || $0.hasPrefix("GIT binary patch") }
        }

        private func fileStatus(
            path: String,
            untrackedPaths: Set<String>
        ) -> DiffReviewFileStatus {
            if untrackedPaths.contains(path) {
                return .untracked
            }
            if fileHeaderLines.contains(where: { $0.hasPrefix("rename from ") || $0.hasPrefix("rename to ") }) {
                return .renamed
            }
            if fileHeaderLines.contains(where: { $0.hasPrefix("copy from ") || $0.hasPrefix("copy to ") }) {
                return .copied
            }
            if fileHeaderLines.contains(where: { $0.hasPrefix("new file mode ") }) {
                return .added
            }
            if fileHeaderLines.contains(where: { $0.hasPrefix("deleted file mode ") }) {
                return .deleted
            }
            if fileHeaderLines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "--- /dev/null" }) {
                return .added
            }
            if fileHeaderLines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "+++ /dev/null" }) {
                return .deleted
            }
            return .modified
        }

        private func pathInfo() -> (path: String, oldPath: String?)? {
            let oldPath = normalizedDiffPath(
                fileHeaderLines.first(where: { $0.hasPrefix("--- ") })?.dropFirst(4)
            )
            let newPath = normalizedDiffPath(
                fileHeaderLines.first(where: { $0.hasPrefix("+++ ") })?.dropFirst(4)
            )
            let renameTo = fileHeaderLines.first(where: { $0.hasPrefix("rename to ") }).map {
                String($0.dropFirst("rename to ".count))
            }
            let renameFrom = fileHeaderLines.first(where: { $0.hasPrefix("rename from ") }).map {
                String($0.dropFirst("rename from ".count))
            }
            let headerPath = pathFromDiffHeader()

            let path = renameTo ?? newPath ?? oldPath ?? headerPath
            guard let path, !path.isEmpty else { return nil }
            let previousPath = renameFrom ?? oldPath
            return (path, previousPath == path ? nil : previousPath)
        }

        private func pathFromDiffHeader() -> String? {
            let payload = String(diffHeader.dropFirst("diff --git ".count))
            let parts = payload.split(separator: " ", maxSplits: 1).map(String.init)
            guard let last = parts.last else { return nil }
            return normalizedDiffPath(last)
        }

        private func normalizedDiffPath<S: StringProtocol>(_ rawPath: S?) -> String? {
            guard let rawPath else { return nil }
            var path = String(rawPath).trimmingCharacters(in: .whitespacesAndNewlines)
            if path == "/dev/null" {
                return nil
            }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
                path.removeFirst()
                path.removeLast()
            }
            if path.hasPrefix("a/") || path.hasPrefix("b/") {
                path = String(path.dropFirst(2))
            }
            return path
        }
    }

    private struct HunkAccumulator {
        let header: String
        private var rawLines: [String] = []

        init(header: String) {
            self.header = header
        }

        mutating func append(_ line: String) {
            rawLines.append(line)
        }

        func build(id: String, fileHeaderLines: [String]) -> DiffReviewHunk {
            let range = hunkRange(header)
            let lines = rawLines.enumerated().map { index, rawLine in
                DiffReviewLine(
                    id: index,
                    kind: lineKind(rawLine),
                    marker: lineMarker(rawLine),
                    text: lineText(rawLine)
                )
            }
            let added = lines.filter { $0.kind == .addition }.count
            let deleted = lines.filter { $0.kind == .deletion }.count
            let patchLines = fileHeaderLines + [header] + rawLines

            return DiffReviewHunk(
                id: id,
                header: header,
                oldStart: range.oldStart,
                oldLength: range.oldLength,
                newStart: range.newStart,
                newLength: range.newLength,
                sectionHeading: range.sectionHeading,
                lines: lines,
                patch: patchLines.joined(separator: "\n") + "\n",
                addedLineCount: added,
                deletedLineCount: deleted
            )
        }

        private func lineKind(_ line: String) -> DiffReviewLineKind {
            if line.hasPrefix("+") { return .addition }
            if line.hasPrefix("-") { return .deletion }
            if line.hasPrefix("\\") { return .metadata }
            return .context
        }

        private func lineMarker(_ line: String) -> String {
            if line.hasPrefix("+") { return "+" }
            if line.hasPrefix("-") { return "-" }
            if line.hasPrefix("\\") { return "\\" }
            return " "
        }

        private func lineText(_ line: String) -> String {
            guard !line.isEmpty else { return "" }
            return String(line.dropFirst())
        }

        private func hunkRange(_ header: String) -> (
            oldStart: Int,
            oldLength: Int,
            newStart: Int,
            newLength: Int,
            sectionHeading: String?
        ) {
            let parts = header.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else {
                return (0, 0, 0, 0, nil)
            }
            let oldRange = parseRange(parts[1])
            let newRange = parseRange(parts[2])
            let heading = sectionHeading(in: header)
            return (oldRange.start, oldRange.length, newRange.start, newRange.length, heading)
        }

        private func parseRange(_ raw: String) -> (start: Int, length: Int) {
            let trimmed = raw.dropFirst()
            let components = trimmed.split(separator: ",", maxSplits: 1).map(String.init)
            let start = Int(components.first ?? "") ?? 0
            let length = components.count > 1 ? (Int(components[1]) ?? 0) : 1
            return (start, length)
        }

        private func sectionHeading(in header: String) -> String? {
            guard let firstRange = header.range(of: "@@"),
                  let secondRange = header[firstRange.upperBound...].range(of: "@@")
            else {
                return nil
            }
            let heading = header[secondRange.upperBound...].trimmingCharacters(in: .whitespaces)
            return heading.isEmpty ? nil : heading
        }
    }
}
