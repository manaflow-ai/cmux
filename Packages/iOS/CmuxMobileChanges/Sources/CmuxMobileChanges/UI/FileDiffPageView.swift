internal import Foundation
public import SwiftUI

/// One independently loading, refreshable diff page.
public struct FileDiffPageView: View {
    let fileIndex: Int
    let file: ChangedFileItem
    let fontSize: Double
    let onFontSizeChanged: @MainActor @Sendable (Double) -> Void
    let onScrollRowIDChanged: @MainActor @Sendable (String?) -> Void
    let onPersistFontSize: @MainActor @Sendable (Double) -> Void
    let onLoad: @MainActor @Sendable (String, Bool, Int?) async throws -> FileDiffPresentation
    let onLoadCurrentLines: @MainActor @Sendable (String) async throws -> DiffExpansionCurrentFile
    let onCopy: @MainActor @Sendable (String) -> Void
    let inlinePreview: (@MainActor @Sendable (_ index: Int, _ revision: FileDiffPreviewRevision) -> AnyView)?
    @State var loadState: FileDiffLoadState = .loading
    @State var scrollRowID: String?
    @State private var magnificationStart: Double?
    @State var previewRevision: FileDiffPreviewRevision = .current
    @State var expansionState = DiffExpansionState()
    @State var currentFileLines: [String]?
    @State var pendingExpansionGapID: Int?
    @State var pendingExpansionDirection: DiffExpansionDirection?
    @State var failedExpansionGapID: Int?
    @State var failedExpansionDirection: DiffExpansionDirection?
    @State var expansionContentTooLarge = false
    @State var expansionTask: Task<Void, Never>?
    @State var continuationTask: Task<Void, Never>?
    @State private var lineBudget = FileDiffContinuation.defaultLineBudget
    @State var continuationLoadState = FileDiffContinuationLoadState.idle
    @State private var reachedTransportCeiling = false
    @State var requestGeneration = FileDiffRequestGeneration()
    @Environment(\.colorScheme) private var colorScheme
    public var body: some View {
        content
            .accessibilityIdentifier("MobileChangesDiffPage-\(file.path)")
            .task(id: file.path) {
                guard case .loading = loadState else { return }
                await load(forceRefresh: false)
            }
            .onDisappear {
                cancelPageTasks()
            }
    }
    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            loadingView
        case .failed:
            failureView
        case .loaded(let presentation):
            documentView(presentation)
        }
    }
    private var loadingView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<24, id: \.self) { index in
                    Text("let placeholder\(index) = true")
                        .font(.system(size: fontSize, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 3)
                }
            }
            .redacted(reason: .placeholder)
        }
    }
    private var failureView: some View {
        ContentUnavailableView {
            Label(
                String(localized: "changes.diff.error.title", defaultValue: "Couldn't load diff", bundle: .module),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(String(
                localized: "changes.diff.error.message",
                defaultValue: "Check the connection to your Mac and try again.",
                bundle: .module
            ))
        } actions: {
            Button(String(localized: "changes.retry", defaultValue: "Retry", bundle: .module)) {
                Task { await load(forceRefresh: true) }
            }
        }
    }
    @ViewBuilder
    private func documentView(_ presentation: FileDiffPresentation) -> some View {
        let document = presentation.document
        if document.isBinary {
            binaryView
        } else {
            let gutterWidth = DiffGutterLayout(
                maximumLineNumber: presentation.maximumLineNumber
            ).measuredWidth(fontSize: fontSize)
            ScrollView {
                let continuation = FileDiffContinuation(
                    lineBudget: lineBudget,
                    document: document,
                    reachedTransportCeiling: reachedTransportCeiling
                )
                LazyVStack(spacing: 0) {
                    ForEach(presentation.rows) { row in
                        diffRow(row, gutterWidth: gutterWidth)
                    }
                    if continuation.shouldShowFooter {
                        FileDiffContinuationFooter(
                            continuation: continuation,
                            state: continuationLoadState,
                            onShowMore: showMore
                        )
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollRowID, anchor: .top)
            .onChange(of: scrollRowID) {
                onScrollRowIDChanged(scrollRowID)
            }
            .refreshable { await load(forceRefresh: true) }
            .simultaneousGesture(magnifyGesture)
        }
    }
    @ViewBuilder
    private func diffRow(_ row: DiffRowSnapshot, gutterWidth: CGFloat) -> some View {
        switch row.content {
        case .line(let line, let hunkCopyText):
            DiffLineRow(
                line: line,
                hunkCopyText: hunkCopyText,
                gutterWidth: gutterWidth,
                fontSize: fontSize,
                theme: theme,
                onCopy: onCopy
            )
            .padding(.top, row.leadingHunkGap ? theme.hunkSpacing : 0)
        case .expander(let snapshot):
            DiffExpanderRow(
                snapshot: snapshot,
                status: expansionRowStatus(for: snapshot),
                interactionDisabled: pendingExpansionGapID != nil,
                theme: theme,
                onExpand: expand
            )
        }
    }
    private var binaryView: some View {
        FileDiffBinaryView(
            fileIndex: fileIndex,
            file: file,
            previewRevision: $previewRevision,
            inlinePreview: inlinePreview
        )
    }
    private var theme: ChangesTheme {
        ChangesTheme(colorScheme: colorScheme)
    }
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = magnificationStart ?? fontSize
                if magnificationStart == nil { magnificationStart = start }
                onFontSizeChanged(clamped(start * value.magnification))
            }
            .onEnded { value in
                let start = magnificationStart ?? fontSize
                let resolved = clamped(start * value.magnification)
                magnificationStart = nil
                onFontSizeChanged(resolved)
                onPersistFontSize(resolved)
            }
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, DiffFontPreference.minimumPointSize), DiffFontPreference.maximumPointSize)
    }

    @MainActor
    func load(forceRefresh: Bool) async {
        cancelContinuationTask()
        let generation = requestGeneration.begin()
        resetExpansion()
        loadState = .loading
        continuationLoadState = .idle
        do {
            let maxLines = lineBudget == FileDiffContinuation.defaultLineBudget
                ? nil
                : lineBudget
            let presentation = try await onLoad(file.path, forceRefresh, maxLines)
            guard !Task.isCancelled,
                  requestGeneration.isCurrent(generation) else { return }
            reachedTransportCeiling = false
            loadState = .loaded(presentation)
        } catch is CancellationError {
            guard requestGeneration.isCurrent(generation),
                  RecoverableCancellationErrorPolicy().shouldPublishFailure(
                      taskIsCancelled: Task.isCancelled
                  ) else { return }
            loadState = .failed
        } catch {
            guard !Task.isCancelled,
                  requestGeneration.isCurrent(generation) else { return }
            loadState = .failed
        }
    }

    @MainActor
    private func showMore() {
        guard case .loaded(let presentation) = loadState,
              continuationLoadState != .loading else { return }
        let document = presentation.document
        let continuation = FileDiffContinuation(
            lineBudget: lineBudget,
            document: document,
            reachedTransportCeiling: reachedTransportCeiling
        )
        guard continuation.canShowMore else { return }
        let nextLineBudget = continuation.nextLineBudget
        cancelContinuationTask()
        let generation = requestGeneration.begin()
        resetExpansion()
        continuationLoadState = .loading
        continuationTask = Task { @MainActor in
            do {
                let expandedPresentation = try await onLoad(file.path, false, nextLineBudget)
                guard !Task.isCancelled,
                      requestGeneration.isCurrent(generation) else { return }
                reachedTransportCeiling = continuation.reachedTransportCeiling(
                    afterLoading: expandedPresentation.document,
                    requestedLineBudget: nextLineBudget
                )
                lineBudget = nextLineBudget
                continuationLoadState = .idle
                loadState = .loaded(expandedPresentation)
                continuationTask = nil
            } catch is CancellationError {
                guard requestGeneration.isCurrent(generation),
                      RecoverableCancellationErrorPolicy().shouldPublishFailure(
                          taskIsCancelled: Task.isCancelled
                      ) else { return }
                continuationLoadState = .failed
                continuationTask = nil
            } catch {
                guard !Task.isCancelled,
                      requestGeneration.isCurrent(generation) else { return }
                continuationLoadState = .failed
                continuationTask = nil
            }
        }
    }
}
