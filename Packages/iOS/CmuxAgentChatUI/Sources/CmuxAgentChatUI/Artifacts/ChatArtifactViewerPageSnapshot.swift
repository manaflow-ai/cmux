import Foundation

/// Immutable render state for one path-keyed artifact viewer page.
struct ChatArtifactViewerPageSnapshot: Identifiable, Equatable {
    let path: String
    let state: ChatArtifactViewerState
    let textChunks: [String]
    let fetchedBytes: Int64
    let totalBytes: Int64?
    let textReachedEOF: Bool
    let markdownPresentation: ChatArtifactMarkdownPresentation
    let textHighlightDecision: ChatArtifactHighlightDecision
    let textLineIndex: ChatArtifactLineIndex
    let hasFileActions: Bool
    let isTextFile: Bool
    let canCopyContents: Bool
    let retryGeneration: Int
    let topRequestID: Int
    let bottomRequestID: Int
    let isSearchPresented: Bool
    let searchQuery: String
    let searchSummary: ChatArtifactSearchSummary
    let previousSearchRequestID: Int
    let nextSearchRequestID: Int
    let showsLineNumbers: Bool
    let isGoToLinePresented: Bool
    let goToLineText: String
    let goToLineUTF16Offset: Int
    let goToLineRequestID: Int
    let wrapsLines: Bool
    let textFontSize: Double
    let fileActionState: ChatArtifactViewerFileActionState

    var id: String { path }

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var renderedText: String {
        textChunks.joined()
    }

    var shouldShowTextJumpControls: Bool {
        state == .text
            || (state == .markdown && markdownPresentation.mode == .raw)
    }

    var hasViewerActions: Bool {
        hasFileActions
            || shouldShowTextJumpControls
            || (state == .markdown && markdownPresentation.isRenderedAvailable)
    }

    var showsHighlightingStatusPill: Bool {
        shouldShowTextJumpControls
            && textHighlightDecision.showsHighlightingOffPill
            && totalBytes != nil
    }
}
