internal import Foundation
public import SwiftUI

/// One independently loading, refreshable diff page.
public struct FileDiffPageView: View {
    private let fileIndex: Int
    private let file: ChangedFileItem
    private let fontSize: Double
    private let onFontSizeChanged: @MainActor @Sendable (Double) -> Void
    private let onPersistFontSize: @MainActor @Sendable (Double) -> Void
    private let onLoad: @MainActor @Sendable (String, Bool) async throws -> FileDiffDocument
    private let onLoadCurrentLines: @MainActor @Sendable (String) async throws -> [String]
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
    @Environment(\.colorScheme) private var colorScheme

    /// Creates one value-driven diff page.
    /// - Parameters:
    ///   - fileIndex: Stable index in the pager's changed-file snapshot.
    ///   - file: File metadata snapshot.
    ///   - initialDocument: Mount-cache hit, when available.
    ///   - fontSize: Current live diff font size.
    ///   - onFontSizeChanged: Live pinch callback.
    ///   - onPersistFontSize: End-of-pinch persistence callback.
    ///   - onLoad: Parsed document loader with a force-refresh flag.
    ///   - onLoadCurrentLines: Fetch-once loader for the current working-tree text.
    ///   - onCopy: Clipboard seam.
    ///   - inlinePreview: Optional binary-preview builder supplied by the composition layer.
    public init(
        fileIndex: Int,
        file: ChangedFileItem,
        initialDocument: FileDiffDocument?,
        fontSize: Double,
        onFontSizeChanged: @escaping @MainActor @Sendable (Double) -> Void,
        onPersistFontSize: @escaping @MainActor @Sendable (Double) -> Void,
        onLoad: @escaping @MainActor @Sendable (String, Bool) async throws -> FileDiffDocument,
        onLoadCurrentLines: @escaping @MainActor @Sendable (String) async throws -> [String],
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
        _loadState = State(initialValue: initialDocument.map(FileDiffLoadState.loaded) ?? .loading)
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
        case .loaded(let document):
            documentView(document)
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
    private func documentView(_ document: FileDiffDocument) -> some View {
        if document.isBinary {
            binaryView
        } else {
            ScrollView {
                let rows = DiffRowSnapshot.rows(
                    for: document,
                    expansionState: expansionState,
                    currentFileLines: currentFileLines,
                    fileKind: file.kind
                )
                let gutterWidth = gutterWidth(for: rows)
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        diffRow(row, gutterWidth: gutterWidth)
                    }
                    if document.truncated {
                        truncatedFooter(lineCount: document.lines.count)
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
        let policy = FileDiffPreviewPolicy(kind: file.kind)
        return VStack(spacing: 0) {
            if policy.allowsRevisionSelection {
                Picker(
                    String(localized: "changes.binary.revision", defaultValue: "Revision", bundle: .module),
                    selection: $previewRevision
                ) {
                    Text(String(localized: "changes.binary.before", defaultValue: "Before", bundle: .module))
                        .tag(FileDiffPreviewRevision.base)
                    Text(String(localized: "changes.binary.after", defaultValue: "After", bundle: .module))
                        .tag(FileDiffPreviewRevision.current)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            if let inlinePreview {
                inlinePreview(fileIndex, previewRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                binaryFallbackView
            }
        }
    }

    private var binaryFallbackView: some View {
        VStack(spacing: 18) {
            binaryFileCard
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.secondary.opacity(0.08))
                .overlay {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 30, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 360, minHeight: 180)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var binaryFileCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 34, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(file.displayFilename)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
            if let byteSize = file.byteSize {
                Text(ByteCountFormatter.string(fromByteCount: max(0, byteSize), countStyle: .file))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func truncatedFooter(lineCount: Int) -> some View {
        Text(String(
            format: String(
                localized: "changes.diff.truncated",
                defaultValue: "Large diff. Showing the first %lld lines to keep things fast. See the rest on your Mac.",
                bundle: .module
            ),
            Int64(lineCount)
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(16)
    }

    private var theme: ChangesTheme {
        ChangesTheme(colorScheme: colorScheme)
    }
    private func gutterWidth(for rows: [DiffRowSnapshot]) -> CGFloat {
        let maximum = rows.reduce(0) { current, row in
            guard case .line(let line, _) = row.content else { return current }
            return max(current, max(line.oldNumber ?? 0, line.newNumber ?? 0))
        }
        return DiffGutterLayout(maximumLineNumber: maximum).measuredWidth(fontSize: fontSize)
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
            reveal(
                snapshot: snapshot,
                direction: direction,
                currentFileLineCount: currentFileLines.count
            )
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
            let lines = try await onLoadCurrentLines(file.path)
            guard !Task.isCancelled else { return }
            currentFileLines = lines
            pendingExpansionGapID = nil
            pendingExpansionDirection = nil
            reveal(
                snapshot: snapshot,
                direction: direction,
                currentFileLineCount: lines.count
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
    ) {
        guard case .loaded(let document) = loadState,
              let gap = DiffGap.gaps(
                for: document,
                currentFileLineCount: currentFileLineCount
              ).first(where: { $0.id == snapshot.gap.id }) else { return }
        expansionState.reveal(
            in: gap,
            direction: direction,
            preferredHiddenRange: snapshot.hiddenNewLineRange
        )
        failedExpansionGapID = nil
        failedExpansionDirection = nil
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
        loadState = .loading
        do {
            let document = try await onLoad(file.path, forceRefresh)
            guard !Task.isCancelled else { return }
            resetExpansion()
            loadState = .loaded(document)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed
        }
    }
}
