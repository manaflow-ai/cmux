/// An immutable diff document paired with its precomputed row projection.
public struct FileDiffPresentation: Sendable, Equatable {
    /// Parsed document represented by this presentation.
    public let document: FileDiffDocument
    let rows: [DiffRowSnapshot]
    let maximumLineNumber: Int

    /// Builds the default row projection away from the caller's actor.
    ///
    /// - Parameters:
    ///   - document: Parsed diff document to project.
    ///   - fileKind: Change kind controlling hidden-context expansion.
    /// - Returns: A presentation ready for one atomic UI-state publication.
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
    }
}
