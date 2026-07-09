import Foundation

/// Converts Codex `apply_patch` input into one file-edit value per patch section.
struct CodexApplyPatchParser: Sendable {
    private let budget: TranscriptTextBudget

    /// Creates a parser using the transcript-wide text budget.
    ///
    /// - Parameter budget: Limit applied to captured per-file patch text.
    init(budget: TranscriptTextBudget) {
        self.budget = budget
    }

    /// Extracts every file operation from a Codex patch payload.
    ///
    /// - Parameter patch: The raw `*** Begin Patch` payload.
    /// - Returns: File edits in patch order.
    func fileEdits(in patch: String) -> [ChatFileEdit] {
        var edits: [ChatFileEdit] = []
        var current: Section?

        for line in patch.components(separatedBy: "\n") {
            if let header = sectionHeader(from: line) {
                if let current {
                    edits.append(fileEdit(from: current))
                }
                current = header
                continue
            }
            guard var section = current else { continue }
            if let movedPath = movedPath(from: line) {
                section.filePath = movedPath
            } else if line != "*** End Patch" {
                section.lines.append(line)
            }
            current = section
        }

        if let current {
            edits.append(fileEdit(from: current))
        }
        return edits
    }

    private func sectionHeader(from line: String) -> Section? {
        let prefixes: [(String, ChatFileEdit.Operation)] = [
            ("*** Update File: ", .edit),
            ("*** Add File: ", .write),
            ("*** Delete File: ", .delete),
        ]
        for (prefix, operation) in prefixes where line.hasPrefix(prefix) {
            let path = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return Section(filePath: path, operation: operation)
        }
        return nil
    }

    private func movedPath(from line: String) -> String? {
        let prefix = "*** Move to: "
        guard line.hasPrefix(prefix) else { return nil }
        let path = String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func fileEdit(from section: Section) -> ChatFileEdit {
        let additions = section.lines.count { line in
            line.hasPrefix("+") && !line.hasPrefix("+++")
        }
        let deletions = section.lines.count { line in
            line.hasPrefix("-") && !line.hasPrefix("---")
        }
        let diff = section.lines.joined(separator: "\n")
        return ChatFileEdit(
            filePath: section.filePath,
            operation: section.operation,
            additions: additions,
            deletions: deletions,
            unifiedDiff: diff.isEmpty ? nil : budget.body(diff)
        )
    }

    private struct Section: Sendable {
        var filePath: String
        let operation: ChatFileEdit.Operation
        var lines: [String] = []
    }
}
