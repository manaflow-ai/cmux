internal import Foundation
public import SwiftUI

/// One independently loading, refreshable diff page.
public struct FileDiffPageView: View {
    private let fileIndex: Int
    private let file: ChangedFileItem
    private let fontSize: Double
    private let onFontSizeChanged: @MainActor @Sendable (Double) -> Void
    private let onPersistFontSize: @MainActor @Sendable (Double) -> Void
    private let onLoad: @MainActor @Sendable (String, Bool, Int?) async throws -> FileDiffPresentation
    private let onLoadCurrentLines: @MainActor @Sendable (String) async throws -> DiffExpansionCurrentFile
    private let onCopy: @MainActor @Sendable (String) -> Void
    private let inlinePreview: (@MainActor @Sendable (_ index: Int, _ revision: FileDiffPreviewRevision) -> AnyView)?
    @State private var loadState: FileDiffLoadState
    @State private var magnificationStart: Double?
    @State private var previewRevision: FileDiffPreviewRevision
    @State private var expansionState = DiffExpansionState()
    @State private var currentFileLines: [String]?
    @State private var pendingExpansionGapID: Int?
    @State private var pendingExpansionDirection: DiffExpansionDirection?
    @State private var failedExpansionGapID: Int?
    @State private var failedExpansionDirection: DiffExpansionDirection?
    @State private var expansionContentTooLarge = false
    @State private var lineBudget = FileDiffContinuation.defaultLineBudget
    @State private var continuationLoadState = FileDiffContinuationLoadState.idle
    @State private var reachedTransportCeiling = false
    @State private var presentationGeneration: UInt64 = 0
    @Environment(\.colorScheme) private var colorScheme
    /// Creates one value-driven diff page.
    /// - Parameters:
    ///   - fileIndex: Stable index in the pager's changed-file snapshot.
    ///   - file: File metadata snapshot.
    ///   - initialPresentation: Mount-cache hit, when available.
    ///   - fontSize: Current live diff font size.
    ///   - onFontSizeChanged: Live pinch callback.
    ///   - onPersistFontSize: End-of-pinch persistence callback.
    ///   - onLoad: Parsed-presentation loader with refresh and optional line-budget inputs.
    ///   - onLoadCurrentLines: Fetch-once loader for the current working-tree text.
    ///   - onCopy: Clipboard seam.
    ///   - inlinePreview: Optional binary-preview builder supplied by the composition layer.
    public init(
        fileIndex: Int,
        file: ChangedFileItem,
        initialPresentation: FileDiffPresentation?,
        fontSize: Double,
        onFontSizeChanged: @escaping @MainActor @Sendable (Double) -> Void,
        onPersistFontSize: @escaping @MainActor @Sendable (Double) -> Void,
        onLoad: @escaping @MainActor @Sendable (String, Bool, Int?) async throws -> FileDiffPresentation,
        onLoadCurrentLines: @escaping @MainActor @Sendable (String) async throws -> DiffExpansionCurrentFile,
        onCopy: @escaping @MainActor @Sendable (String) -> Void,
        inlinePreview: (@MainActor @Sendable (_ index: Int, _ revision: FileDiffPreviewRevision) -> AnyView)? = nil
    ) {
        self.fileIndex = fileIndex
        self.file = file
        self.fontSize = fontSize
        self.onFontSizeChanged = onFontSizeChanged
        self.onPersistFontSize = onPersistFontSize
        self.onLoad = onLoad
        self.onLoadCurrentLines = onLoadCurrentLines
        self.onCopy = onCopy
        self.inlinePreview = inlinePreview
        _loadState = State(initialValue: initialPresentation.map(FileDiffLoadState.loaded) ?? .loading)
        _previewRevision = State(initialValue: FileDiffPreviewPolicy(kind: file.kind).defaultRevision)
    }
    public var body: some View {
        content
            .accessibilityIdentifier("MobileChangesDiffPage-\(file.path)")
            .task(id: file.path) {
                guard case .loading = loadState else { return }
                await load(forceRefresh: false)
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
    private func expansionRowStatus(for snapshot: DiffExpanderSnapshot) -> DiffExpansionRowStatus {
        if expansionContentTooLarge { return .tooLarge }
        if pendingExpansionGapID == snapshot.gap.id,
           let pendingExpansionDirection {
            return .loading(pendingExpansionDirection)
        }
        if failedExpansionGapID == snapshot.gap.id,
           let failedExpansionDirection {
            return .failed(failedExpansionDirection)
        }
        return .ready
    }
    @MainActor
    private func expand(
        _ snapshot: DiffExpanderSnapshot,
        direction: DiffExpansionDirection
    ) {
        guard pendingExpansionGapID == nil, !expansionContentTooLarge else { return }
        if let currentFileLines {
            Task {
                await reveal(
                    snapshot: snapshot,
                    direction: direction,
                    currentFileLineCount: currentFileLines.count
                )
            }
            return
        }
        pendingExpansionGapID = snapshot.gap.id
        pendingExpansionDirection = direction
        failedExpansionGapID = nil
        failedExpansionDirection = nil
        Task {
            await loadCurrentLinesAndExpand(snapshot: snapshot, direction: direction)
        }
    }

    @MainActor
    private func loadCurrentLinesAndExpand(
        snapshot: DiffExpanderSnapshot,
        direction: DiffExpansionDirection
    ) async {
        do {
            let currentFile = try await onLoadCurrentLines(file.path)
            guard !Task.isCancelled else { return }
            guard case .loaded(let presentation) = loadState else { return }
            let revisionDecision = DiffExpansionRevisionPolicy().decision(
                diffContentFingerprint: presentation.document.contentFingerprint,
                fetchedContentFingerprints: currentFile.contentFingerprints
            )
            guard revisionDecision == .accept else {
                resetExpansion()
                await load(forceRefresh: true)
                return
            }
            currentFileLines = currentFile.lines
            pendingExpansionGapID = nil
            pendingExpansionDirection = nil
            await reveal(
                snapshot: snapshot,
                direction: direction,
                currentFileLineCount: currentFile.lines.count
            )
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            pendingExpansionGapID = nil
            pendingExpansionDirection = nil
            failedExpansionGapID = snapshot.gap.id
            failedExpansionDirection = direction
        } catch DiffExpansionContentError.tooLarge {
            guard !Task.isCancelled else { return }
            pendingExpansionGapID = nil
            pendingExpansionDirection = nil
            expansionContentTooLarge = true
        } catch {
            guard !Task.isCancelled else { return }
            pendingExpansionGapID = nil
            pendingExpansionDirection = nil
            failedExpansionGapID = snapshot.gap.id
            failedExpansionDirection = direction
        }
    }

    @MainActor
    private func reveal(
        snapshot: DiffExpanderSnapshot,
        direction: DiffExpansionDirection,
        currentFileLineCount: Int
    ) async {
        guard case .loaded(let presentation) = loadState else { return }
        let document = presentation.document
        guard let gap = DiffGap.gaps(
            for: document,
            currentFileLineCount: currentFileLineCount
        ).first(where: { $0.id == snapshot.gap.id }) else {
            await recomputePresentation(for: document)
            return
        }
        expansionState.reveal(
            in: gap,
            direction: direction,
            preferredHiddenRange: snapshot.hiddenNewLineRange
        )
        failedExpansionGapID = nil
        failedExpansionDirection = nil
        await recomputePresentation(for: document)
    }

    @MainActor
    private func resetExpansion() {
        expansionState = DiffExpansionState()
        currentFileLines = nil
        pendingExpansionGapID = nil
        pendingExpansionDirection = nil
        failedExpansionGapID = nil
        failedExpansionDirection = nil
        expansionContentTooLarge = false
    }

    @MainActor
    private func recomputePresentation(for document: FileDiffDocument) async {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let presentation = await FileDiffPresentation.prepareOffMain(
            document: document,
            expansionState: expansionState,
            currentFileLines: currentFileLines,
            fileKind: file.kind
        )
        guard !Task.isCancelled,
              presentationGeneration == generation,
              case .loaded(let currentPresentation) = loadState,
              currentPresentation.document == document else { return }
        loadState = .loaded(presentation)
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
    private func load(forceRefresh: Bool) async {
        presentationGeneration &+= 1
        loadState = .loading
        continuationLoadState = .idle
        do {
            let maxLines = lineBudget == FileDiffContinuation.defaultLineBudget
                ? nil
                : lineBudget
            let presentation = try await onLoad(file.path, forceRefresh, maxLines)
            guard !Task.isCancelled else { return }
            reachedTransportCeiling = false
            resetExpansion()
            loadState = .loaded(presentation)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
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
        continuationLoadState = .loading
        Task {
            do {
                let expandedPresentation = try await onLoad(file.path, false, nextLineBudget)
                guard !Task.isCancelled else { return }
                reachedTransportCeiling = continuation.reachedTransportCeiling(
                    afterLoading: expandedPresentation.document,
                    requestedLineBudget: nextLineBudget
                )
                lineBudget = nextLineBudget
                continuationLoadState = .idle
                presentationGeneration &+= 1
                resetExpansion()
                loadState = .loaded(expandedPresentation)
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                continuationLoadState = .failed
            } catch {
                guard !Task.isCancelled else { return }
                continuationLoadState = .failed
            }
        }
    }
}
