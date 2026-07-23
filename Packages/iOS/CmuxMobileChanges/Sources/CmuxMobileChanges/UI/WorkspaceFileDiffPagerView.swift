public import SwiftUI

/// Swipe-paged diff viewer over an immutable changed-file snapshot.
public struct WorkspaceFileDiffPagerView: View {
    private let files: [ChangedFileItem]
    private let cachedDocuments: [String: FileDiffDocument]
    private let actions: WorkspaceFileDiffPagerActions
    @State private var selection: Int
    @State private var fontSize: Double

    /// Creates a file diff pager.
    /// - Parameters:
    ///   - files: Stable changed-file snapshot.
    ///   - initialSelectedIndex: File index opened from the list.
    ///   - cachedDocuments: Parsed documents already held by the mount layer.
    ///   - initialFontSize: Persisted font size snapshot.
    ///   - actions: Loading, persistence, and clipboard closures.
    public init(
        files: [ChangedFileItem],
        initialSelectedIndex: Int,
        cachedDocuments: [String: FileDiffDocument],
        initialFontSize: Double,
        actions: WorkspaceFileDiffPagerActions
    ) {
        self.files = files
        self.cachedDocuments = cachedDocuments
        self.actions = actions
        let validIndex = files.isEmpty ? 0 : min(max(initialSelectedIndex, 0), files.count - 1)
        _selection = State(initialValue: validIndex)
        _fontSize = State(initialValue: min(
            max(initialFontSize, DiffFontPreference.minimumPointSize),
            DiffFontPreference.maximumPointSize
        ))
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            pager
        }
        .accessibilityIdentifier("MobileChangesDiffPager")
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(currentFile?.displayFilename ?? "")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(DiffPagerPosition(selectedIndex: selection, pageCount: files.count).localizedText)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var pager: some View {
        #if os(iOS)
        pages
            .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        pages
        #endif
    }

    private var pages: some View {
        TabView(selection: $selection) {
            ForEach(Array(files.enumerated()), id: \.element.path) { index, file in
                let fontSizeChanged: @MainActor @Sendable (Double) -> Void = {
                    fontSize = $0
                }
                FileDiffPageView(
                    fileIndex: index,
                    file: file,
                    initialDocument: cachedDocuments[file.path],
                    fontSize: fontSize,
                    onFontSizeChanged: fontSizeChanged,
                    onPersistFontSize: actions.onPersistFontSize,
                    onLoad: actions.onLoad,
                    onLoadCurrentLines: actions.onLoadCurrentLines,
                    onCopy: actions.onCopy,
                    inlinePreview: index == selection ? actions.inlinePreview : nil
                )
                .tag(index)
            }
        }
    }

    private var currentFile: ChangedFileItem? {
        guard files.indices.contains(selection) else { return nil }
        return files[selection]
    }
}
