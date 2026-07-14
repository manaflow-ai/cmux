import CmuxMobileRPC
import Testing

@testable import CmuxMobileDiff

@Suite struct DiffScrollAnchorResolverTests {
    @Test func mapsAddedUnifiedRowToItsSplitPair() throws {
        let file = fileSnapshot(isCollapsed: false)
        let addition = try #require(file.rows.first { $0.kind == .addition })
        let resolver = DiffScrollAnchorResolver()
        let resolved = resolver.resolvedAnchor(
            addition.id,
            visibleFilePath: file.path,
            files: [file],
            mode: .split
        )
        let splitRows = DiffRowBuilder().projectedRows(file.rows, mode: .split)
        let pair = try #require(splitRows.first { $0.sourceRowIDs.contains(addition.id) })
        #expect(resolved == pair.id)
    }

    @Test func collapsedVisibleRowFallsBackToStableFileHeader() throws {
        let expanded = fileSnapshot(isCollapsed: false)
        let row = try #require(expanded.rows.first { $0.kind == .deletion })
        let collapsed = fileSnapshot(isCollapsed: true)
        let resolver = DiffScrollAnchorResolver()
        #expect(resolver.containsVisibleAnchor(row.id, files: [expanded], mode: .unified))
        #expect(!resolver.containsVisibleAnchor(row.id, files: [collapsed], mode: .unified))
        #expect(resolver.resolvedAnchor(
            "removed-row",
            visibleFilePath: collapsed.path,
            files: [collapsed],
            mode: .unified
        ) == collapsed.path)
    }

    private func fileSnapshot(isCollapsed: Bool) -> DiffFileSnapshot {
        let file = MobileChangesFile(
            path: "Sources/App.swift",
            oldPath: nil,
            status: .modified,
            additions: 1,
            deletions: 1,
            isBinary: false,
            isLarge: false,
            patchDigest: "digest"
        )
        let rows = DiffRowBuilder().rows(
            file: file,
            hunks: [MobileChangesHunk(
                oldStart: 1,
                oldLines: 1,
                newStart: 1,
                newLines: 1,
                sectionHeading: nil,
                rows: [
                    MobileChangesDiffRow(kind: .del, oldNo: 1, newNo: nil, text: "old"),
                    MobileChangesDiffRow(kind: .add, oldNo: nil, newNo: 1, text: "new"),
                ]
            )],
            includeEOFGap: false
        )
        return DiffFileSnapshot(
            file: file,
            rows: rows,
            isCollapsed: isCollapsed,
            isViewed: false,
            isLoading: false
        )
    }
}
