internal import CmuxMobileRPC

@MainActor
final class PreviewChangesService: MobileChangesLoading {
    func summary(baseSpec: MobileChangesBaseSpec, ignoreWhitespace: Bool) async throws -> MobileChangesSummaryResponse {
        MobileChangesSummaryResponse(
            baseInfo: MobileChangesBaseInfo(kind: baseSpec.kind, resolvedRef: "HEAD", describe: "Working tree"),
            totals: MobileChangesTotals(files: 3, additions: 18, deletions: 7),
            files: [
                MobileChangesFile(
                    path: "Sources/App/WorkspaceView.swift",
                    oldPath: nil,
                    status: .modified,
                    additions: 9,
                    deletions: 5,
                    isBinary: false,
                    isLarge: false,
                    patchDigest: "preview-swift"
                ),
                MobileChangesFile(
                    path: "Assets/preview.png",
                    oldPath: nil,
                    status: .added,
                    additions: 0,
                    deletions: 0,
                    isBinary: true,
                    isLarge: false,
                    patchDigest: "preview-binary"
                ),
                MobileChangesFile(
                    path: "generated/output.json",
                    oldPath: nil,
                    status: .modified,
                    additions: 9,
                    deletions: 2,
                    isBinary: false,
                    isLarge: true,
                    patchDigest: "preview-large"
                ),
            ],
            truncatedFileCount: 0
        )
    }

    func fileDiff(
        path: String,
        oldPath: String?,
        cursor: String?,
        ignoreWhitespace: Bool,
        baseSpec: MobileChangesBaseSpec
    ) async throws -> MobileChangesFileResponse {
        MobileChangesFileResponse(
            hunks: [
                MobileChangesHunk(
                    oldStart: 12,
                    oldLines: 5,
                    newStart: 12,
                    newLines: 6,
                    sectionHeading: "var body: some View",
                    rows: [
                        MobileChangesDiffRow(kind: .context, oldNo: 12, newNo: 12, text: "    VStack(alignment: .leading) {"),
                        MobileChangesDiffRow(kind: .del, oldNo: 13, newNo: nil, text: "        Text(\"Old title\")"),
                        MobileChangesDiffRow(kind: .add, oldNo: nil, newNo: 13, text: "        Text(\"Native changes\")"),
                        MobileChangesDiffRow(kind: .add, oldNo: nil, newNo: 14, text: "            .font(.headline)"),
                        MobileChangesDiffRow(kind: .context, oldNo: 14, newNo: 15, text: "        Spacer()"),
                        MobileChangesDiffRow(kind: .context, oldNo: 15, newNo: 16, text: "    }"),
                        MobileChangesDiffRow(kind: .noNewline, oldNo: nil, newNo: nil, text: ""),
                    ]
                ),
            ],
            isBinary: false,
            tooLarge: false,
            nextCursor: nil
        )
    }

    func contextLines(
        path: String,
        start: Int,
        end: Int,
        baseSpec: MobileChangesBaseSpec
    ) async throws -> MobileChangesContextResponse {
        MobileChangesContextResponse(rows: (start...end).map { "// Context line \($0)" })
    }
}
