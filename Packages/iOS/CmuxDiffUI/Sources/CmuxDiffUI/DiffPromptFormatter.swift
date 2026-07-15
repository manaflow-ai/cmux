import Foundation

struct DiffPromptFormatter: Sendable {
    let maximumExcerptCharacters: Int

    init(maximumExcerptCharacters: Int = 4_000) {
        self.maximumExcerptCharacters = maximumExcerptCharacters
    }

    func format(target: DiffQuickNoteTarget, note: String) -> String {
        let localized = DiffLocalized()
        let preview = preview(target: target)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteBody = trimmedNote.isEmpty
            ? localized.string("diff.quickNote.noNote", defaultValue: "No additional note.")
            : trimmedNote
        return [
            localized.string(
                "diff.quickNote.promptInstruction",
                defaultValue: "Review this exact diff target and respond to the note."
            ),
            "",
            preview,
            "",
            localized.string("diff.quickNote.noteHeading", defaultValue: "Note:"),
            noteBody,
        ].joined(separator: "\n")
    }

    func preview(target: DiffQuickNoteTarget) -> String {
        let localized = DiffLocalized()
        let excerpt = truncatedExcerpt(target.excerpt)
        let fence = codeFence(for: excerpt)
        var lines = [
            "\(localized.string("diff.quickNote.fileHeading", defaultValue: "File:")) \(escapedPath(target.path))",
            "\(localized.string("diff.quickNote.newTargetHeading", defaultValue: "New target:")) \(reference(path: target.path, range: target.newLineRange))",
            "\(localized.string("diff.quickNote.oldTargetHeading", defaultValue: "Old target:")) \(reference(path: target.path, range: target.oldLineRange))",
        ]
        if let hunkHeader = target.hunkHeader, !hunkHeader.isEmpty {
            lines.append("\(localized.string("diff.quickNote.hunkHeading", defaultValue: "Hunk:")) \(hunkHeader)")
        }
        lines.append(localized.string("diff.quickNote.excerptHeading", defaultValue: "Excerpt:"))
        lines.append("\(fence)diff")
        lines.append(excerpt.isEmpty
            ? localized.string("diff.quickNote.excerptUnavailable", defaultValue: "Diff excerpt is not loaded.")
            : excerpt)
        lines.append(fence)
        return lines.joined(separator: "\n")
    }

    private func truncatedExcerpt(_ excerpt: String) -> String {
        guard excerpt.count > maximumExcerptCharacters else { return excerpt }
        let suffix = DiffLocalized().string(
            "diff.quickNote.excerptTruncated",
            defaultValue: "… [excerpt truncated]"
        )
        let retainedCount = max(0, maximumExcerptCharacters - suffix.count - 1)
        return "\(excerpt.prefix(retainedCount))\n\(suffix)"
    }

    private func codeFence(for excerpt: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in excerpt {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: max(3, longestRun + 1))
    }

    private func reference(path: String, range: ClosedRange<Int>?) -> String {
        guard let range else {
            return "\(escapedPath(path)):\(DiffLocalized().string("diff.quickNote.linesUnavailable", defaultValue: "lines unavailable"))"
        }
        if range.lowerBound == range.upperBound {
            return "\(escapedPath(path)):\(range.lowerBound)"
        }
        return "\(escapedPath(path)):\(range.lowerBound)-\(range.upperBound)"
    }

    private func escapedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
