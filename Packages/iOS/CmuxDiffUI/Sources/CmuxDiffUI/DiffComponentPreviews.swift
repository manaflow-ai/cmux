#if DEBUG
import SwiftUI

#Preview("Full diff fixture") {
    NavigationStack {
        DiffFixtureScreen(
            defaults: UserDefaults(suiteName: "DiffFixturePreview") ?? .standard
        )
    }
}

#Preview("Summary header") {
    DiffSummaryHeaderView(
        fileCount: 11,
        additions: 3215,
        deletions: 23,
        viewedCount: 3,
        baseLabel: "main · working tree"
    )
    .padding()
}

#Preview("File list row") {
    let patchSet = DiffFixtureFactory().patchSet()
    let file = patchSet.files[0]
    let rows = DiffRowBuilder().rows(
        path: file.summary.path,
        hunks: {
            if case let .loaded(hunks) = file.content { hunks } else { [] }
        }()
    )
    DiffFileListRow(
        state: DiffFilePresentationState(
            file: file,
            isViewed: false,
            isCollapsed: false,
            rows: rows,
            splitRows: SplitDiffPairer().pair(rows: rows)
        ),
        toggleViewed: {},
        toggleCollapsed: {}
    )
    .padding()
}

#Preview("Unified diff row") {
    let row = DiffRowSnapshot(
        id: "preview",
        kind: .addition,
        oldLine: nil,
        newLine: 42,
        text: "let greeting = \"Hello\"",
        hunkIndex: 0
    )
    DiffUnifiedRowView(row: row, highlighted: nil, expand: { _ in })
}
#endif
