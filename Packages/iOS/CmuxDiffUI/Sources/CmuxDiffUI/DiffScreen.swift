public import SwiftUI

/// Native changed-file list and continuous diff body for one workspace patch set.
public struct DiffScreen: View {
    @Binding private var renderMode: DiffRenderMode
    @State private var fileStates: [DiffFilePresentationState]

    private let patchSet: DiffPatchSet
    private let viewedStore: DiffViewedStore
    private let highlighter: any CodeHighlighting
    private let actions: DiffScreenActions

    /// Creates a complete diff rendering surface.
    /// - Parameters:
    ///   - patchSet: Immutable file summaries and available bodies.
    ///   - renderMode: Binding that selects unified or split presentation.
    ///   - viewedStore: Injected device-local viewed persistence.
    ///   - highlighter: Injected asynchronous syntax highlighter.
    ///   - actions: Host callbacks for data operations not owned by this slice.
    public init(
        patchSet: DiffPatchSet,
        renderMode: Binding<DiffRenderMode>,
        viewedStore: DiffViewedStore,
        highlighter: any CodeHighlighting,
        actions: DiffScreenActions
    ) {
        self.patchSet = patchSet
        _renderMode = renderMode
        self.viewedStore = viewedStore
        self.highlighter = highlighter
        self.actions = actions
        _fileStates = State(initialValue: DiffPresentationBuilder().states(
            patchSet: patchSet,
            viewedStore: viewedStore
        ))
    }

    /// The native list and its sticky per-file sections.
    public var body: some View {
        DiffContinuousView(
            fileStates: fileStates,
            totalFileCount: fileStates.count,
            additions: totalAdditions,
            deletions: totalDeletions,
            baseLabel: patchSet.baseLabel,
            renderMode: renderMode,
            scrollTarget: nil,
            scrollRequestID: 0,
            showFileIndex: true,
            highlighter: highlighter,
            actions: DiffContinuousActions(
                loadFile: { path, force in
                    guard let state = fileStates.first(where: { $0.file.summary.path == path }) else {
                        return
                    }
                    if force {
                        actions.loadLargeFile(state.file)
                    } else if case .failed = state.file.content {
                        actions.retryFile(state.file)
                    }
                },
                expandContext: actions.expandContext,
                toggleViewed: toggleViewed,
                toggleCollapsed: toggleCollapsed,
                collapseAll: collapseAll,
                refresh: {}
            )
        )
    }

    private var totalAdditions: Int {
        fileStates.reduce(0) { $0 + $1.file.summary.additions }
    }

    private var totalDeletions: Int {
        fileStates.reduce(0) { $0 + $1.file.summary.deletions }
    }

    @MainActor private func toggleViewed(path: String) {
        guard let index = fileStates.firstIndex(where: { $0.file.summary.path == path }) else { return }
        fileStates[index].isViewed.toggle()
        if fileStates[index].isViewed {
            fileStates[index].isCollapsed = true
        }
        let state = fileStates[index]
        viewedStore.setViewed(
            state.isViewed,
            workspaceID: patchSet.workspaceID,
            path: state.file.summary.path,
            patchDigest: state.file.summary.patchDigest
        )
    }

    @MainActor private func toggleCollapsed(path: String) {
        guard let index = fileStates.firstIndex(where: { $0.file.summary.path == path }) else { return }
        fileStates[index].isCollapsed.toggle()
    }

    @MainActor private func collapseAll() {
        for index in fileStates.indices {
            fileStates[index].isCollapsed = true
        }
    }
}
