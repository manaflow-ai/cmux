public import SwiftUI

/// One independently loading, refreshable diff page.
public struct FileDiffPageView: View {
    private let file: ChangedFileItem
    private let fontSize: Double
    private let onFontSizeChanged: @MainActor @Sendable (Double) -> Void
    private let onPersistFontSize: @MainActor @Sendable (Double) -> Void
    private let onLoad: @MainActor @Sendable (String, Bool) async throws -> FileDiffDocument
    private let onCopy: @MainActor @Sendable (String) -> Void
    @State private var loadState: FileDiffLoadState
    @State private var magnificationStart: Double?
    @Environment(\.colorScheme) private var colorScheme

    /// Creates one value-driven diff page.
    /// - Parameters:
    ///   - file: File metadata snapshot.
    ///   - initialDocument: Mount-cache hit, when available.
    ///   - fontSize: Current live diff font size.
    ///   - onFontSizeChanged: Live pinch callback.
    ///   - onPersistFontSize: End-of-pinch persistence callback.
    ///   - onLoad: Parsed document loader with a force-refresh flag.
    ///   - onCopy: Clipboard seam.
    public init(
        file: ChangedFileItem,
        initialDocument: FileDiffDocument?,
        fontSize: Double,
        onFontSizeChanged: @escaping @MainActor @Sendable (Double) -> Void,
        onPersistFontSize: @escaping @MainActor @Sendable (Double) -> Void,
        onLoad: @escaping @MainActor @Sendable (String, Bool) async throws -> FileDiffDocument,
        onCopy: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.file = file
        self.fontSize = fontSize
        self.onFontSizeChanged = onFontSizeChanged
        self.onPersistFontSize = onPersistFontSize
        self.onLoad = onLoad
        self.onCopy = onCopy
        _loadState = State(initialValue: initialDocument.map(FileDiffLoadState.loaded) ?? .loading)
    }

    public var body: some View {
        content
            .accessibilityIdentifier("MobileChangesDiffPage-\(file.path)")
            .task(id: file.path) {
                guard case .loading = loadState else { return }
                await load(forceRefresh: false)
            }
            .simultaneousGesture(magnifyGesture)
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

    private func documentView(_ document: FileDiffDocument) -> some View {
        ScrollView {
            if document.isBinary {
                binaryView
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(hunkSnapshots(document)) { snapshot in
                        hunkView(snapshot.hunk, gutterWidth: gutterWidth(for: document))
                            .padding(.top, snapshot.index == 0 ? 0 : theme.hunkSpacing)
                    }
                    if document.truncated {
                        truncatedFooter(lineCount: document.lines.count)
                    }
                }
            }
        }
        .refreshable { await load(forceRefresh: true) }
    }

    private func hunkView(_ hunk: DiffHunk, gutterWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            DiffLineRow(
                line: hunk.header,
                hunkCopyText: hunk.copyText,
                gutterWidth: gutterWidth,
                fontSize: fontSize,
                theme: theme,
                onCopy: onCopy
            )
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                DiffLineRow(
                    line: line,
                    hunkCopyText: hunk.copyText,
                    gutterWidth: gutterWidth,
                    fontSize: fontSize,
                    theme: theme,
                    onCopy: onCopy
                )
            }
        }
    }

    private var binaryView: some View {
        ContentUnavailableView {
            Label(
                String(localized: "changes.binary.title", defaultValue: "Binary file not shown", bundle: .module),
                systemImage: "doc.circle"
            )
        }
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

    private func hunkSnapshots(_ document: FileDiffDocument) -> [DiffHunkSnapshot] {
        document.hunks.enumerated().map { DiffHunkSnapshot(index: $0.offset, hunk: $0.element) }
    }

    private func gutterWidth(for document: FileDiffDocument) -> CGFloat {
        let maximum = document.lines.reduce(0) { current, line in
            max(current, max(line.oldNumber ?? 0, line.newNumber ?? 0))
        }
        return DiffGutterLayout(maximumLineNumber: maximum).measuredWidth(fontSize: fontSize)
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
            loadState = .loaded(document)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed
        }
    }
}
