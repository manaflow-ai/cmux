import CmuxMobileRPC

struct DiffFixtureFactory: Sendable {
    func patchSet() -> DiffPatchSet {
        DiffPatchSet(
            workspaceID: "ndv2-fixture-workspace",
            baseLabel: DiffLocalized().string(
                "diff.fixture.baseLabel",
                defaultValue: "main · working tree"
            ),
            files: [
                modifiedFile(),
                addedFile(),
                deletedFile(),
                renamedFile(),
                copiedFile(),
                untrackedFile(),
                binaryFile(),
                largeFile(),
                noNewlineFile(),
                unicodeLongLineFile(),
                failedFile(),
            ]
        )
    }

    private func modifiedFile() -> DiffFileSnapshot {
        file(
            path: "Sources/Greeting.swift",
            status: .modified,
            additions: 2,
            deletions: 2,
            digest: "modified-v1",
            content: .loaded([
                hunk(
                    oldStart: 8,
                    oldLines: 5,
                    newStart: 8,
                    newLines: 5,
                    heading: "func greeting(for name: String) -> String",
                    rows: [
                        row(.context, "func greeting(for name: String) -> String {"),
                        row(.del, "    let message = \"Hello, \\(name)!\""),
                        row(.del, "    return message"),
                        row(.add, "    let message = \"Welcome back, \\(name)!\""),
                        row(.add, "    return message.uppercased()"),
                        row(.context, "}"),
                    ]
                ),
            ])
        )
    }

    private func addedFile() -> DiffFileSnapshot {
        file(
            path: "Sources/Features/NewPanel.swift",
            status: .added,
            additions: 4,
            deletions: 0,
            digest: "added-v1",
            content: .loaded([
                hunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 4, heading: nil, rows: [
                    row(.add, "import SwiftUI"),
                    row(.add, "struct NewPanel: View {"),
                    row(.add, "    var body: some View { Text(verbatim: \"Hello\") }"),
                    row(.add, "}"),
                ]),
            ])
        )
    }

    private func deletedFile() -> DiffFileSnapshot {
        file(
            path: "Sources/Legacy/OldPanel.swift",
            status: .deleted,
            additions: 0,
            deletions: 3,
            digest: "deleted-v1",
            content: .loaded([
                hunk(oldStart: 1, oldLines: 3, newStart: 0, newLines: 0, heading: nil, rows: [
                    row(.del, "struct OldPanel {"),
                    row(.del, "    let title: String"),
                    row(.del, "}"),
                ]),
            ])
        )
    }

    private func renamedFile() -> DiffFileSnapshot {
        file(
            path: "Sources/Models/Session.swift",
            oldPath: "Sources/Models/Run.swift",
            status: .renamed,
            additions: 0,
            deletions: 0,
            digest: "rename-v1",
            content: .renameOnly
        )
    }

    private func copiedFile() -> DiffFileSnapshot {
        file(
            path: "Sources/Templates/CardCopy.swift",
            oldPath: "Sources/Templates/Card.swift",
            status: .copied,
            additions: 1,
            deletions: 0,
            digest: "copy-v1",
            content: .loaded([
                hunk(oldStart: 4, oldLines: 2, newStart: 4, newLines: 3, heading: "var body: some View", rows: [
                    row(.context, "VStack {"),
                    row(.add, "    Divider()"),
                    row(.context, "}"),
                ]),
            ])
        )
    }

    private func untrackedFile() -> DiffFileSnapshot {
        file(
            path: "scratch/ideas.txt",
            status: .untracked,
            additions: 3,
            deletions: 0,
            digest: "untracked-v1",
            content: .loaded([
                hunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 3, heading: nil, rows: [
                    row(.add, "Native diff viewer"),
                    row(.add, "Fast scrolling"),
                    row(.add, "Device-local viewed state"),
                ]),
            ])
        )
    }

    private func binaryFile() -> DiffFileSnapshot {
        file(
            path: "Assets/AppIcon.png",
            status: .modified,
            additions: 0,
            deletions: 0,
            digest: "binary-v1",
            content: .binary,
            isBinary: true
        )
    }

    private func largeFile() -> DiffFileSnapshot {
        file(
            path: "Generated/API.generated.swift",
            status: .modified,
            additions: 3200,
            deletions: 14,
            digest: "large-v1",
            content: .large,
            isLarge: true
        )
    }

    private func noNewlineFile() -> DiffFileSnapshot {
        file(
            path: "docs/release-note.md",
            status: .modified,
            additions: 1,
            deletions: 1,
            digest: "newline-v1",
            content: .loaded([
                hunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, heading: nil, rows: [
                    row(.del, "Old ending"),
                    row(.noNewline, ""),
                    row(.add, "New ending"),
                    row(.noNewline, ""),
                ]),
            ])
        )
    }

    private func unicodeLongLineFile() -> DiffFileSnapshot {
        file(
            path: "Sources/国際化/挨拶.swift",
            status: .modified,
            additions: 1,
            deletions: 1,
            digest: "unicode-v1",
            content: .loaded([
                hunk(oldStart: 20, oldLines: 1, newStart: 20, newLines: 1, heading: "", rows: [
                    row(.del, "let greeting = \"こんにちは\" + String(repeating: \"—very-long-line—\", count: 8)"),
                    row(.add, "let greeting = \"こんばんは\" + String(repeating: \"—very-long-line—\", count: 8)"),
                ]),
            ])
        )
    }

    private func failedFile() -> DiffFileSnapshot {
        file(
            path: "Sources/Remote/Unavailable.swift",
            status: .modified,
            additions: 2,
            deletions: 1,
            digest: "failed-v1",
            content: .failed(DiffLocalized().string(
                "diff.fixture.loadError",
                defaultValue: "The fixture could not load this file."
            ))
        )
    }

    private func file(
        path: String,
        oldPath: String? = nil,
        status: MobileDiffFileStatus,
        additions: Int,
        deletions: Int,
        digest: String,
        content: DiffFileContent,
        isBinary: Bool = false,
        isLarge: Bool = false
    ) -> DiffFileSnapshot {
        DiffFileSnapshot(
            summary: MobileDiffFileSummary(
                path: path,
                oldPath: oldPath,
                status: status,
                additions: additions,
                deletions: deletions,
                isBinary: isBinary,
                isLarge: isLarge,
                patchDigest: digest
            ),
            content: content
        )
    }

    private func hunk(
        oldStart: Int,
        oldLines: Int,
        newStart: Int,
        newLines: Int,
        heading: String?,
        rows: [MobileDiffRow]
    ) -> MobileDiffHunk {
        MobileDiffHunk(
            oldStart: oldStart,
            oldLines: oldLines,
            newStart: newStart,
            newLines: newLines,
            sectionHeading: heading,
            rows: rows
        )
    }

    private func row(_ kind: MobileDiffRowKind, _ text: String) -> MobileDiffRow {
        MobileDiffRow(kind: kind, text: text)
    }
}
