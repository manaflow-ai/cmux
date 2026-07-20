import CmuxAgentChat
import Foundation
import Observation

/// Owns mutable content and controls for one stable artifact path.
@Observable
@MainActor
final class ChatArtifactViewerPageModel {
    let path: String

    private let viewerModel: ChatArtifactViewerModel
    private let textPreferences: ChatArtifactTextPreferences
    private let textLayoutKind: ChatArtifactTextLayoutKind
    private(set) var retryGeneration = 0
    private(set) var topRequestID = 0
    private(set) var bottomRequestID = 0
    private(set) var isSearchPresented = false
    private(set) var searchQuery = ""
    private(set) var searchSummary = ChatArtifactSearchSummary.empty
    private(set) var previousSearchRequestID = 0
    private(set) var nextSearchRequestID = 0
    private(set) var showsLineNumbers = true
    private(set) var isGoToLinePresented = false
    private(set) var goToLineText = ""
    private(set) var goToLineUTF16Offset = 0
    private(set) var goToLineRequestID = 0
    private(set) var wrapsLines: Bool
    private(set) var textFontSize: Double
    private(set) var fileActionState = ChatArtifactViewerFileActionState()

    init(
        path: String,
        textPreferences: ChatArtifactTextPreferences,
        viewerModel: ChatArtifactViewerModel = ChatArtifactViewerModel()
    ) {
        self.path = path
        self.textPreferences = textPreferences
        self.viewerModel = viewerModel
        let layoutKind = ChatArtifactTextLayoutKind(path: path)
        textLayoutKind = layoutKind
        wrapsLines = textPreferences.wrapsLines(for: layoutKind)
        textFontSize = textPreferences.fontSize(for: layoutKind)
    }

    var snapshot: ChatArtifactViewerPageSnapshot {
        ChatArtifactViewerPageSnapshot(
            path: path,
            state: viewerModel.state,
            textChunks: viewerModel.textChunks,
            fetchedBytes: viewerModel.fetchedBytes,
            totalBytes: viewerModel.totalBytes,
            textReachedEOF: viewerModel.textReachedEOF,
            markdownPresentation: viewerModel.markdownPresentation,
            textHighlightDecision: viewerModel.textHighlightDecision,
            textLineIndex: viewerModel.textLineIndex,
            hasFileActions: viewerModel.hasFileActions,
            isTextFile: viewerModel.isTextFile,
            canCopyContents: viewerModel.canCopyContents,
            retryGeneration: retryGeneration,
            topRequestID: topRequestID,
            bottomRequestID: bottomRequestID,
            isSearchPresented: isSearchPresented,
            searchQuery: searchQuery,
            searchSummary: searchSummary,
            previousSearchRequestID: previousSearchRequestID,
            nextSearchRequestID: nextSearchRequestID,
            showsLineNumbers: showsLineNumbers,
            isGoToLinePresented: isGoToLinePresented,
            goToLineText: goToLineText,
            goToLineUTF16Offset: goToLineUTF16Offset,
            goToLineRequestID: goToLineRequestID,
            wrapsLines: wrapsLines,
            textFontSize: textFontSize,
            fileActionState: fileActionState
        )
    }

    func load(
        loader: ChatArtifactLoader,
        quickLookCanPreview: @MainActor (URL) -> Bool
    ) async {
        await viewerModel.load(
            path: path,
            loader: loader,
            quickLookCanPreview: quickLookCanPreview
        )
    }

    func cleanup() async {
        await viewerModel.cleanup()
    }

    func actions(
        loader: ChatArtifactLoader,
        quickLookCanPreview: @escaping @MainActor (URL) -> Bool
    ) -> ChatArtifactViewerPageActions {
        ChatArtifactViewerPageActions(
            load: {
                await self.load(
                    loader: loader,
                    quickLookCanPreview: quickLookCanPreview
                )
            },
            cleanup: { await self.cleanup() },
            retry: { self.retry() },
            setSearchQuery: { self.setSearchQuery($0) },
            setSearchSummary: { self.setSearchSummary($0) },
            selectPreviousSearchResult: { self.selectPreviousSearchResult() },
            selectNextSearchResult: { self.selectNextSearchResult() },
            dismissSearch: { self.dismissSearch() },
            setGoToLineText: { self.setGoToLineText($0) },
            goToLine: { self.goToLine($0) },
            dismissGoToLine: { self.dismissGoToLine() },
            setFontSize: { self.setFontSize($0) }
        )
    }

    func retry() {
        retryGeneration += 1
    }

    func toggleSearch() {
        if isSearchPresented {
            dismissSearch()
        } else {
            dismissGoToLine()
            isSearchPresented = true
        }
    }

    func dismissSearch() {
        isSearchPresented = false
        searchQuery = ""
        searchSummary = .empty
    }

    func setSearchQuery(_ query: String) {
        searchQuery = query
    }

    func setSearchSummary(_ summary: ChatArtifactSearchSummary) {
        searchSummary = summary
    }

    func selectPreviousSearchResult() {
        previousSearchRequestID += 1
    }

    func selectNextSearchResult() {
        nextSearchRequestID += 1
    }

    func toggleGoToLine() {
        if isGoToLinePresented {
            dismissGoToLine()
        } else {
            dismissSearch()
            isGoToLinePresented = true
        }
    }

    func dismissGoToLine() {
        isGoToLinePresented = false
        goToLineText = ""
    }

    func setGoToLineText(_ text: String) {
        goToLineText = text
    }

    func goToLine(_ requestedLine: Int) {
        let line = viewerModel.textLineIndex.clampedLine(requestedLine)
        goToLineText = String(line)
        goToLineUTF16Offset = viewerModel.textLineIndex.offset(forLine: line)
        goToLineRequestID += 1
    }

    func requestTop() {
        topRequestID += 1
    }

    func requestBottom() {
        bottomRequestID += 1
    }

    func toggleLineNumbers() {
        showsLineNumbers.toggle()
    }

    func toggleWordWrap() {
        wrapsLines.toggle()
        textPreferences.setWrapsLines(wrapsLines, for: textLayoutKind)
    }

    func setFontSize(_ fontSize: Double) {
        textFontSize = textPreferences.setFontSize(fontSize, for: textLayoutKind)
    }

    func selectMarkdownMode(_ mode: ChatArtifactMarkdownMode) {
        if mode == .rendered {
            dismissSearch()
            dismissGoToLine()
        }
        viewerModel.selectMarkdownMode(mode)
    }

    #if os(iOS)
    func prepareShare(loader: ChatArtifactLoader) async {
        await prepareFileAction(loader: loader, presentation: ChatArtifactFileActionPresentation.share)
    }

    func prepareSave(loader: ChatArtifactLoader) async {
        await prepareFileAction(loader: loader, presentation: ChatArtifactFileActionPresentation.save)
    }

    func setFileActionPresentation(_ presentation: ChatArtifactFileActionPresentation?) {
        fileActionState.presentation = presentation
    }

    func setShowsFileActionError(_ isPresented: Bool) {
        fileActionState.showsError = isPresented
    }

    private func prepareFileAction(
        loader: ChatArtifactLoader,
        presentation: (URL) -> ChatArtifactFileActionPresentation
    ) async {
        guard !fileActionState.isRunning else { return }
        fileActionState.isRunning = true
        defer { fileActionState.isRunning = false }
        do {
            let fileURL = try await ChatArtifactFileActionStore.applicationDefault.materialize(
                path: path,
                loader: loader
            )
            try Task.checkCancellation()
            fileActionState.presentation = presentation(fileURL)
        } catch is CancellationError {
            return
        } catch {
            fileActionState.showsError = true
        }
    }
    #endif
}
