import Foundation

/// Converts unified patch text into numbered display hunks.
struct UnifiedDiffParser: Sendable {
    func parse(_ patch: Data) -> [DiffHunk] {
        let lines = String(decoding: patch, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var hunks: [DiffHunk] = []
        var index = 0
        while index < lines.count {
            guard let header = parseHeader(lines[index]) else {
                index += 1
                continue
            }
            index += 1
            var oldNumber = header.oldStart
            var newNumber = header.newStart
            var rows: [DiffRow] = []
            while index < lines.count, !lines[index].hasPrefix("@@ ") {
                let line = lines[index]
                if line.hasPrefix("diff --git ") { break }
                if line.hasPrefix("\\ No newline at end of file") {
                    rows.append(DiffRow(kind: .noNewline, oldNo: nil, newNo: nil, text: "No newline at end of file"))
                } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    rows.append(DiffRow(kind: .add, oldNo: nil, newNo: newNumber, text: String(line.dropFirst())))
                    newNumber += 1
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
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
                index += 1
            }
            hunks.append(DiffHunk(
                oldStart: header.oldStart,
                oldLines: header.oldLines,
                newStart: header.newStart,
                newLines: header.newLines,
                sectionHeading: header.sectionHeading,
                rows: rows
            ))
        }
        return hunks
    }

    private func parseHeader(_ line: String) -> Header? {
        guard line.hasPrefix("@@ "),
              let closing = line.range(of: " @@", range: line.index(line.startIndex, offsetBy: 3)..<line.endIndex) else {
            return nil
        }
        let coordinates = line[line.index(line.startIndex, offsetBy: 3)..<closing.lowerBound]
            .split(separator: " ")
        guard coordinates.count == 2,
              let oldRange = parseRange(String(coordinates[0]), prefix: "-"),
              let newRange = parseRange(String(coordinates[1]), prefix: "+") else {
            return nil
        }
        let headingStart = closing.upperBound
        let heading = line[headingStart...].trimmingCharacters(in: .whitespaces)
        return Header(
            oldStart: oldRange.start,
            oldLines: oldRange.count,
            newStart: newRange.start,
            newLines: newRange.count,
            sectionHeading: heading.isEmpty ? nil : heading
        )
    }

    private func parseRange(_ value: String, prefix: Character) -> (start: Int, count: Int)? {
        guard value.first == prefix else { return nil }
        let parts = value.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(parts[0]) else { return nil }
        let count = parts.count > 1 ? Int(parts[1]) ?? 0 : 1
        return (start, count)
    }

    private struct Header {
        let oldStart: Int
        let oldLines: Int
        let newStart: Int
        let newLines: Int
        let sectionHeading: String?
    }
}
