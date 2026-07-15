struct DiffPresentationBuilder: Sendable {
    private let rowBuilder = DiffRowBuilder()
    private let splitPairer = SplitDiffPairer()

    func states(patchSet: DiffPatchSet, viewedStore: DiffViewedStore) -> [DiffFilePresentationState] {
        patchSet.files.map { file in
            let rows: [DiffRowSnapshot]
            if case let .loaded(hunks) = file.content {
                rows = rowBuilder.rows(path: file.summary.path, hunks: hunks)
            } else {
                rows = []
            }
            let isViewed = viewedStore.isViewed(
                workspaceID: patchSet.workspaceID,
                path: file.summary.path,
                patchDigest: file.summary.patchDigest
            )
            return DiffFilePresentationState(
                file: file,
                isViewed: isViewed,
                isCollapsed: isViewed,
                rows: rows,
                splitRows: splitPairer.pair(rows: rows)
            )
        }
    }
}
