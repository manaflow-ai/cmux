internal import CoreGraphics

/// An immutable diff document paired with its precomputed row and gutter projection.
public struct FileDiffPresentation: Sendable, Equatable {
    /// Parsed document represented by this presentation.
    public let document: FileDiffDocument
    let rows: [DiffRowSnapshot]
    let gutterWidth: CGFloat
    let fontSize: Double

    /// Builds the default row and gutter projection away from the caller's actor.
    ///
    /// - Parameters:
    ///   - document: Parsed diff document to project.
    ///   - fileKind: Change kind controlling hidden-context expansion.
    ///   - fontSize: Monospaced diff font size used to measure the gutter.
    /// - Returns: A presentation ready for one atomic UI-state publication.
    public nonisolated static func prepareOffMain(
        document: FileDiffDocument,
        fileKind: FileChangeKind,
        fontSize: Double
    ) async -> FileDiffPresentation {
        make(
            document: document,
            expansionState: DiffExpansionState(),
            currentFileLines: nil,
            fileKind: fileKind,
            fontSize: fontSize
        )
    }

    nonisolated static func prepareOffMain(
        document: FileDiffDocument,
        expansionState: DiffExpansionState,
        currentFileLines: [String]?,
        fileKind: FileChangeKind,
        fontSize: Double
    ) async -> FileDiffPresentation {
        make(
            document: document,
            expansionState: expansionState,
            currentFileLines: currentFileLines,
            fileKind: fileKind,
            fontSize: fontSize
        )
    }

    static func make(
        document: FileDiffDocument,
        expansionState: DiffExpansionState,
        currentFileLines: [String]?,
        fileKind: FileChangeKind,
        fontSize: Double
    ) -> FileDiffPresentation {
        let rows = DiffRowSnapshot.rows(
            for: document,
            expansionState: expansionState,
            currentFileLines: currentFileLines,
            fileKind: fileKind
        )
        let maximumLineNumber = DiffRowSnapshot.maximumLineNumber(in: rows)
        let gutterWidth = DiffGutterLayout(maximumLineNumber: maximumLineNumber)
            .measuredWidth(fontSize: fontSize)
        return FileDiffPresentation(
            document: document,
            rows: rows,
            gutterWidth: gutterWidth,
            fontSize: fontSize
        )
    }

    private init(
        document: FileDiffDocument,
        rows: [DiffRowSnapshot],
        gutterWidth: CGFloat,
        fontSize: Double
    ) {
        self.document = document
        self.rows = rows
        self.gutterWidth = gutterWidth
        self.fontSize = fontSize
    }
}
