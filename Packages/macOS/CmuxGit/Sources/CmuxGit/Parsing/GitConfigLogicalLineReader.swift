import Foundation

/// Folds Git config physical lines joined by an unescaped trailing backslash.
struct GitConfigLogicalLineReader {
    /// Returns logical lines while preserving continuation-line whitespace.
    func lines(from config: String) -> [String] {
        var logicalLines: [String] = []
        var pendingLine: String?

        for physicalLine in config.components(separatedBy: .newlines) {
            if pendingLine == nil {
                pendingLine = physicalLine
            } else {
                pendingLine?.append(contentsOf: physicalLine)
            }

            guard var line = pendingLine else { continue }
            if hasUnescapedTrailingBackslash(line) {
                line.removeLast()
                pendingLine = line
                continue
            }

            logicalLines.append(line)
            pendingLine = nil
        }

        if let pendingLine {
            logicalLines.append(pendingLine)
        }
        return logicalLines
    }

    private func hasUnescapedTrailingBackslash(_ line: String) -> Bool {
        var trailingBackslashCount = 0
        for character in line.reversed() {
            guard character == "\\" else { break }
            trailingBackslashCount += 1
        }
        return trailingBackslashCount.isMultiple(of: 2) == false
    }
}
