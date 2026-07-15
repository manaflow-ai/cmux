public import SwiftUI

/// Native changed-file list and continuous diff body for one workspace patch set.
public struct DiffScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding private var renderMode: DiffRenderMode
    @State private var fileStates: [DiffFilePresentationState]
    @State private var highlights: [String: HighlightedCode] = [:]
    @State private var highlightBatcher: CodeHighlightBatcher

    private let patchSet: DiffPatchSet
    private let viewedStore: DiffViewedStore
    private let actions: DiffScreenActions
    private let clipboard = DiffClipboardWriter()

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
        self.actions = actions
        _highlightBatcher = State(initialValue: CodeHighlightBatcher(highlighter: highlighter))
        _fileStates = State(initialValue: DiffPresentationBuilder().states(
            patchSet: patchSet,
            viewedStore: viewedStore
        ))
    }

    /// The native list and its sticky per-file sections.
    public var body: some View {
        let requests = highlightRequests(for: DiffColorScheme(colorScheme))
        List {
            Section {
                DiffSummaryHeaderView(
                    fileCount: fileStates.count,
                    additions: totalAdditions,
                    deletions: totalDeletions,
                    viewedCount: viewedCount,
                    baseLabel: patchSet.baseLabel
                )
            }
            .listRowSeparator(.hidden)

            Section(filesSectionLabel) {
                ForEach(fileStates) { state in
                    DiffFileListRow(
                        state: state,
                        toggleViewed: { toggleViewed(path: state.file.summary.path) },
                        toggleCollapsed: { toggleCollapsed(path: state.file.summary.path) }
                    )
                }
            }

            ForEach(sectionSnapshots) { snapshot in
                Section {
                    if !snapshot.state.isCollapsed {
                        bodyRows(for: snapshot)
                    }
                } header: {
                    DiffFileSectionHeader(
                        state: snapshot.state,
                        toggleCollapsed: { toggleCollapsed(path: snapshot.state.file.summary.path) },
                        toggleViewed: { toggleViewed(path: snapshot.state.file.summary.path) },
                        copyPath: { clipboard.copy(snapshot.state.file.summary.path) },
                        collapseAll: collapseAll
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .task(id: requests) {
            highlights = await highlightBatcher.highlights(for: requests)
        }
    }

    @ViewBuilder
    private func bodyRows(for snapshot: DiffFileSectionSnapshot) -> some View {
        switch snapshot.state.file.content {
        case .binary:
            DiffPlaceholderRow(kind: .binary, action: {})
        case .large:
            DiffPlaceholderRow(kind: .large) {
                actions.loadLargeFile(snapshot.state.file)
            }
        case .renameOnly:
            DiffPlaceholderRow(kind: .renameOnly, action: {})
        case let .failed(message):
            DiffPlaceholderRow(kind: .failed(message)) {
                actions.retryFile(snapshot.state.file)
            }
        case .loaded:
            if renderMode == .unified {
                ForEach(snapshot.state.rows) { row in
                    DiffUnifiedRowView(
                        row: row,
                        highlighted: snapshot.highlights[row.id],
                        expand: { direction in
                            actions.expandContext(DiffContextExpansionRequest(
                                path: snapshot.state.file.summary.path,
                                hunkIndex: row.hunkIndex,
                                direction: direction
                            ))
                        }
                    )
                }
            } else {
                ForEach(snapshot.state.splitRows) { row in
                    DiffSplitRowView(
                        row: row,
                        highlights: snapshot.highlights,
                        expand: { direction in
                            actions.expandContext(DiffContextExpansionRequest(
                                path: snapshot.state.file.summary.path,
                                hunkIndex: row.spanning?.hunkIndex
                                    ?? row.old?.hunkIndex
                                    ?? row.new?.hunkIndex
                                    ?? 0,
                                direction: direction
                            ))
                        }
                    )
                }
            }
        }
    }

    private var sectionSnapshots: [DiffFileSectionSnapshot] {
        fileStates.map { state in
            DiffFileSectionSnapshot(state: state, highlights: highlights)
        }
    }

    private var totalAdditions: Int {
        fileStates.reduce(0) { $0 + $1.file.summary.additions }
    }

    private var totalDeletions: Int {
        fileStates.reduce(0) { $0 + $1.file.summary.deletions }
    }

    private var viewedCount: Int {
        fileStates.count(where: \.isViewed)
    }

    private var filesSectionLabel: String {
        DiffLocalized().string("diff.files.title", defaultValue: "Files")
    }

    private func highlightRequests(for scheme: DiffColorScheme) -> [CodeHighlightRequest] {
        let mapper = DiffLanguageMapper()
        return fileStates.flatMap { state -> [CodeHighlightRequest] in
            let language = mapper.language(for: state.file.summary.path)
            return state.rows.compactMap { row in
                switch row.kind {
                case .context, .addition, .deletion:
                    CodeHighlightRequest(
                        id: row.id,
                        language: language,
                        line: row.text,
                        colorScheme: scheme
                    )
                case .hunkHeader, .noNewline:
                    nil
                }
            }
        }
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
