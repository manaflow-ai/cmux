public import SwiftUI

/// Swipe-paged diff viewer over an immutable changed-file snapshot.
public struct WorkspaceFileDiffPagerView: View {
    private let files: [ChangedFileItem]
    private let cachedPresentations: [String: FileDiffPresentation]
    private let actions: WorkspaceFileDiffPagerActions
    private let mountPolicy = DiffPagerMountPolicy()
    @State private var selection: Int
    @State private var fontSize: Double
    @State private var scrollRowIDsByPath: [String: String] = [:]

    /// Creates a file diff pager.
    /// - Parameters:
    ///   - files: Stable changed-file snapshot.
    ///   - initialSelectedIndex: File index opened from the list.
    ///   - cachedPresentations: Parsed and projected diffs already held by the mount layer.
    ///   - initialFontSize: Persisted font size snapshot.
    ///   - actions: Loading, persistence, and clipboard closures.
    public init(
        files: [ChangedFileItem],
        initialSelectedIndex: Int,
        cachedPresentations: [String: FileDiffPresentation],
        initialFontSize: Double,
        actions: WorkspaceFileDiffPagerActions
    ) {
        self.files = files
        self.cachedPresentations = cachedPresentations
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
        .onAppear(perform: recordSelectedPresentationAccess)
        .onChange(of: selection) {
            recordSelectedPresentationAccess()
        }
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
                Group {
                    if mountPolicy.shouldMount(
                        pageIndex: index,
                        selectedIndex: selection
                    ) {
                        let scrollRowIDChanged: @MainActor @Sendable (String?) -> Void = {
                            guard let rowID = $0 else { return }
                            scrollRowIDsByPath[file.path] = rowID
                        }
                        FileDiffPageView(
                            fileIndex: index,
                            file: file,
                            initialPresentation: cachedPresentations[file.path],
                            initialScrollRowID: scrollRowIDsByPath[file.path],
                            fontSize: fontSize,
                            onFontSizeChanged: fontSizeChanged,
                            onScrollRowIDChanged: scrollRowIDChanged,
                            onPersistFontSize: actions.onPersistFontSize,
                            onLoad: actions.onLoad,
                            onLoadCurrentLines: actions.onLoadCurrentLines,
                            onCopy: actions.onCopy,
                            inlinePreview: index == selection ? actions.inlinePreview : nil
                        )
                    } else {
                        Color.clear
                            .accessibilityHidden(true)
                    }
                }
                .tag(index)
            }
        }
    }

    private var currentFile: ChangedFileItem? {
        guard files.indices.contains(selection) else { return nil }
        return files[selection]
    }

    @MainActor
    private func recordSelectedPresentationAccess() {
        guard let currentFile else { return }
        actions.onPresentationAccess(currentFile.path)
    }
}
