/// An immutable diff document paired with its precomputed row projection.
public struct FileDiffPresentation: Sendable, Equatable {
    /// Parsed document represented by this presentation.
    public let document: FileDiffDocument
    let rows: [DiffRowSnapshot]
    let maximumLineNumber: Int
    /// Document-order position of each row id. `onScrollTargetVisibilityChange`
    /// does not guarantee the order of the ids it reports, so the topmost
    /// visible row must be resolved against this index rather than taken
    /// positionally from the callback array.
    let rowOrderIndex: [String: Int]

    /// Builds the default row projection away from the caller's actor.
    ///
    /// - Parameters:
    ///   - document: Parsed diff document to project.
    ///   - fileKind: Change kind controlling hidden-context expansion.
    /// - Returns: A presentation ready for one atomic UI-state publication.
    @concurrent
    public nonisolated static func prepareOffMain(
        document: FileDiffDocument,
        fileKind: FileChangeKind
    ) async -> FileDiffPresentation {
        make(
            document: document,
            expansionState: DiffExpansionState(),
            currentFileLines: nil,
            fileKind: fileKind
        )
    }

    @concurrent
    nonisolated static func prepareOffMain(
        document: FileDiffDocument,
        expansionState: DiffExpansionState,
        currentFileLines: [String]?,
        fileKind: FileChangeKind
    ) async -> FileDiffPresentation {
        make(
            document: document,
            expansionState: expansionState,
            currentFileLines: currentFileLines,
            fileKind: fileKind
        )
    }

    /// Builds an expansion projection that cooperatively stops when superseded.
    @concurrent
    nonisolated static func prepareOffMainCancellable(
        document: FileDiffDocument,
        expansionState: DiffExpansionState,
        currentFileLines: [String],
        fileKind: FileChangeKind
    ) async -> FileDiffPresentation? {
        guard !Task.isCancelled,
              let rows = DiffRowSnapshot.cancellableRows(
                  for: document,
                  expansionState: expansionState,
                  currentFileLines: currentFileLines,
                  fileKind: fileKind
              ),
              !Task.isCancelled else { return nil }
        return FileDiffPresentation(
            document: document,
            rows: rows,
            maximumLineNumber: DiffRowSnapshot.maximumLineNumber(in: rows)
        )
    }

    static func make(
        document: FileDiffDocument,
        expansionState: DiffExpansionState,
        currentFileLines: [String]?,
        fileKind: FileChangeKind
    ) -> FileDiffPresentation {
        let rows = DiffRowSnapshot.rows(
            for: document,
            expansionState: expansionState,
            currentFileLines: currentFileLines,
            fileKind: fileKind
        )
        return FileDiffPresentation(
            document: document,
            rows: rows,
            maximumLineNumber: DiffRowSnapshot.maximumLineNumber(in: rows)
        )
    }

    private init(
        document: FileDiffDocument,
        rows: [DiffRowSnapshot],
        maximumLineNumber: Int
    ) {
        self.document = document
        self.rows = rows
        self.maximumLineNumber = maximumLineNumber
        self.rowOrderIndex = Dictionary(
            rows.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
