public import SwiftUI

/// Swipe-paged diff viewer over an immutable changed-file snapshot.
///
/// Page state (cached presentations, scroll positions) lives in a
/// render-inert reference store, and on iOS the page hierarchy is owned by
/// UIKit, so async cache writes cannot rebuild the pager mid-gesture. See
/// `DiffPagerContainerView` for the ownership invariant.
public struct WorkspaceFileDiffPagerView: View {
    private let files: [ChangedFileItem]
    private let store: FileDiffPresentationStore
    private let actions: WorkspaceFileDiffPagerActions
    private let prefetchPolicy = DiffPagerPrefetchPolicy()
    @State private var selection: Int
    @State private var pageEnvironment: DiffPagerPageEnvironment

    /// Creates a file diff pager.
    /// - Parameters:
    ///   - files: Stable changed-file snapshot.
    ///   - initialSelectedIndex: File index opened from the list.
    ///   - presentationStore: Render-inert store holding parsed diffs and
    ///     per-page scroll positions across page mounts.
    ///   - initialFontSize: Persisted font size snapshot.
    ///   - actions: Loading, persistence, and clipboard closures.
    public init(
        files: [ChangedFileItem],
        initialSelectedIndex: Int,
        presentationStore: FileDiffPresentationStore,
        initialFontSize: Double,
        actions: WorkspaceFileDiffPagerActions
    ) {
        self.files = files
        store = presentationStore
        self.actions = actions
        let validIndex = files.isEmpty ? 0 : min(max(initialSelectedIndex, 0), files.count - 1)
        _selection = State(initialValue: validIndex)
        let clampedFontSize = min(
            max(initialFontSize, DiffFontPreference.minimumPointSize),
            DiffFontPreference.maximumPointSize
        )
        _pageEnvironment = State(initialValue: DiffPagerPageEnvironment(
            fontSize: clampedFontSize,
            selectedIndex: validIndex
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
            pageEnvironment.selectedIndex = selection
            recordSelectedPresentationAccess()
        }
        // Warm nearby pages while the user reads the current one, so a swipe
        // lands on content instead of a placeholder that pops in mid-slide.
        // Loads land in the render-inert store, so a landing (or an LRU
        // eviction) never re-renders the pager; a canceled batch (fast
        // consecutive swipes) is retried by the next selection's task.
        .task(id: selection) {
            let paths = prefetchPolicy.prefetchPaths(
                files: files,
                selectedIndex: selection,
                cachedPaths: store.cachedPaths
            )
            // Sequential, nearest first: the page most likely to be swiped to
            // warms first, and a canceled tail simply retries next selection.
            for path in paths {
                guard !Task.isCancelled else { return }
                _ = try? await actions.onLoad(path, false, nil)
            }
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
        DiffPagerContainerView(
            files: files,
            initialSelectedIndex: selection,
            makePage: { index, file in
                AnyView(pageRoot(index: index, file: file))
            },
            onSelectionChanged: { selection = $0 }
        )
        #else
        // Non-iOS builds exist only for the macOS test host; a plain TabView
        // keeps the package compiling without UIKit.
        TabView(selection: $selection) {
            ForEach(Array(files.enumerated()), id: \.element.path) { index, file in
                pageRoot(index: index, file: file)
                    .tag(index)
            }
        }
        #endif
    }

    private func pageRoot(index: Int, file: ChangedFileItem) -> some View {
        DiffPagerPageRoot(
            index: index,
            file: file,
            pageEnvironment: pageEnvironment,
            store: store,
            actions: actions
        )
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

/// One page's SwiftUI subtree, rehydrated from the store at mount.
///
/// Reads the shared page environment so pinch-driven font changes and
/// selection gating re-render only mounted page subtrees, never the
/// container.
private struct DiffPagerPageRoot: View {
    let index: Int
    let file: ChangedFileItem
    let pageEnvironment: DiffPagerPageEnvironment
    let store: FileDiffPresentationStore
    let actions: WorkspaceFileDiffPagerActions

    var body: some View {
        FileDiffPageView(
            fileIndex: index,
            file: file,
            initialPresentation: store.presentation(forPath: file.path),
            initialScrollRowID: store.scrollRowID(forPath: file.path),
            fontSize: pageEnvironment.fontSize,
            onFontSizeChanged: { pageEnvironment.fontSize = $0 },
            onScrollRowIDChanged: { store.setScrollRowID($0, forPath: file.path) },
            onPersistFontSize: actions.onPersistFontSize,
            onLoad: actions.onLoad,
            onLoadCurrentLines: actions.onLoadCurrentLines,
            onCopy: actions.onCopy,
            inlinePreview: index == pageEnvironment.selectedIndex ? actions.inlinePreview : nil
        )
    }
}
