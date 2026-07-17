import CmuxMobileRPC
import SwiftUI

struct DiffContinuousView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var highlights: [String: HighlightedCode] = [:]
    @State private var highlightBatcher: CodeHighlightBatcher

    let fileStates: [DiffFilePresentationState]
    let totalFileCount: Int
    let additions: Int
    let deletions: Int
    let baseLabel: String
    let baseKind: MobileDiffBaseKind
    let ignoreWhitespace: Bool
    let renderMode: DiffRenderMode
    let scrollTarget: String?
    let scrollRequestID: Int
    let showFileIndex: Bool
    let actions: DiffContinuousActions
    private let clipboard = DiffClipboardWriter()

    init(
        fileStates: [DiffFilePresentationState],
        totalFileCount: Int,
        additions: Int,
        deletions: Int,
        baseLabel: String,
        baseKind: MobileDiffBaseKind,
        ignoreWhitespace: Bool,
        renderMode: DiffRenderMode,
        scrollTarget: String?,
        scrollRequestID: Int,
        showFileIndex: Bool,
        highlighter: any CodeHighlighting,
        actions: DiffContinuousActions
    ) {
        self.fileStates = fileStates
        self.totalFileCount = totalFileCount
        self.additions = additions
        self.deletions = deletions
        self.baseLabel = baseLabel
        self.baseKind = baseKind
        self.ignoreWhitespace = ignoreWhitespace
        self.renderMode = renderMode
        self.scrollTarget = scrollTarget
        self.scrollRequestID = scrollRequestID
        self.showFileIndex = showFileIndex
        self.actions = actions
        _highlightBatcher = State(initialValue: CodeHighlightBatcher(highlighter: highlighter))
    }

    var body: some View {
        let requests = highlightRequests(for: DiffColorScheme(colorScheme))
        ScrollViewReader { proxy in
            List {
                Section {
                    DiffSummaryHeaderView(
                        fileCount: totalFileCount,
                        additions: additions,
                        deletions: deletions,
                        viewedCount: viewedCount,
                        baseLabel: baseLabel,
                        baseKind: baseKind,
                        ignoreWhitespace: ignoreWhitespace,
                        selectBase: actions.selectBase,
                        setIgnoreWhitespace: actions.setIgnoreWhitespace
                    )
                }
                .listRowSeparator(.hidden)

                if showFileIndex {
                    Section(filesSectionLabel) {
                        ForEach(fileStates) { state in
                            DiffFileListRow(
                                state: state,
                                toggleViewed: { actions.toggleViewed(state.file.summary.path) },
                                toggleCollapsed: { actions.toggleCollapsed(state.file.summary.path) }
                            )
                        }
                    }
                }

                ForEach(sectionSnapshots) { snapshot in
                    Section {
                        if !snapshot.state.isCollapsed {
                            DiffFileBodyView(
                                snapshot: snapshot,
                                renderMode: renderMode,
                                actions: actions
                            )
                        }
                    } header: {
                        DiffFileSectionHeader(
                            state: snapshot.state,
                            toggleCollapsed: {
                                actions.toggleCollapsed(snapshot.state.file.summary.path)
                                if snapshot.state.isCollapsed {
                                    actions.loadFile(snapshot.state.file.summary.path, false)
                                }
                            },
                            toggleViewed: { actions.toggleViewed(snapshot.state.file.summary.path) },
                            copyPath: { clipboard.copy(snapshot.state.file.summary.path) },
                            collapseAll: actions.collapseAll,
                            quickNoteTarget: DiffQuickNoteTargetFactory().fileTarget(state: snapshot.state),
                            quickNoteAvailable: actions.quickNoteAvailable,
                            openQuickNote: actions.openQuickNote
                        )
                        .id(DiffTreeScrollTargetResolver().sectionID(
                            path: snapshot.state.file.summary.path
                        ))
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            #if os(iOS)
            .listRowSpacing(0)
            #endif
            .refreshable {
                await actions.refresh()
            }
            .task(id: scrollRequestID) {
                guard let scrollTarget else { return }
                await Task.yield()
                withAnimation {
                    proxy.scrollTo(scrollTarget, anchor: .top)
                }
            }
        }
        .task(id: requests) {
            highlights = await highlightBatcher.highlights(for: requests)
        }
    }

    private var sectionSnapshots: [DiffFileSectionSnapshot] {
        fileStates.map { state in
            DiffFileSectionSnapshot(state: state, highlights: highlights)
        }
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
}
