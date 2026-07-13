#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShell
import SwiftUI

struct TerminalArtifactContext: Identifiable {
    let workspaceID: String
    let surfaceID: String
    let anchor: UnitPoint

    var id: String { "\(workspaceID)#\(surfaceID)" }
}

struct TerminalArtifactSelection: Identifiable, Equatable {
    let workspaceID: String
    let surfaceID: String
    let path: String

    var id: String { "\(workspaceID)#\(surfaceID)#\(path)" }
}

struct TerminalArtifactFilesSheet: View {
    let workspaceID: String
    let surfaceID: String
    let source: MobileChatEventSource?
    let loader: ChatArtifactLoader

    @State private var inViewState: InViewLoadState = .loading
    @State private var sessionState: SessionLoadState = .idle
    @State private var searchState: SessionLoadState = .idle
    @State private var sessionID: String?
    @State private var sessionLoader = ChatArtifactLoader.unsupported()
    @State private var scope: Scope = .session
    @State private var viewMode: ViewMode = .list
    @State private var searchQuery = ""
    @State private var selection: TerminalArtifactPathSelection?
    @State private var createdExpanded = true
    @State private var attachedExpanded = true
    @State private var referencedExpanded = true
    @State private var thumbnailPrefetchTasks: [Task<Void, Never>] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if sessionID != nil {
                    scopePicker
                    Divider()
                }
                activeContent
            }
            .navigationTitle(String(
                localized: "terminal.artifact.gallery.title",
                defaultValue: "Files",
                bundle: .module
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(
                        localized: "terminal.artifact.gallery.done",
                        defaultValue: "Done",
                        bundle: .module
                    )) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    viewModePicker
                }
            }
        }
        .frame(idealWidth: 380, idealHeight: 520)
        .task(id: "\(workspaceID)#\(surfaceID)") {
            await loadInitial()
        }
        .sheet(item: $selection) { selection in
            ChatArtifactViewerSheet(
                path: selection.path,
                scope: selection.scope == .session ? .chat : .terminal
            )
            .environment(
                \.chatArtifactLoader,
                selection.scope == .session ? sessionLoader : loader
            )
        }
        .onDisappear {
            thumbnailPrefetchTasks.forEach { $0.cancel() }
            thumbnailPrefetchTasks.removeAll()
        }
    }

    private var scopePicker: some View {
        Picker(
            String(
                localized: "terminal.artifact.gallery.scope",
                defaultValue: "Scope",
                bundle: .module
            ),
            selection: $scope
        ) {
            Text(String(
                localized: "terminal.artifact.gallery.scope.session",
                defaultValue: "Session",
                bundle: .module
            ))
            .tag(Scope.session)
            Text(String(
                localized: "terminal.artifact.gallery.scope.in_view",
                defaultValue: "In view",
                bundle: .module
            ))
            .tag(Scope.inView)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // Keep the existing single toolbar menu so the content picker never creates
    // a second glass-backed segmented control in the navigation bar.
    private var viewModePicker: some View {
        Menu {
            Picker(
                String(
                    localized: "terminal.artifact.gallery.view_mode",
                    defaultValue: "View",
                    bundle: .module
                ),
                selection: $viewMode
            ) {
                Label(
                    String(
                        localized: "terminal.artifact.gallery.view_mode.list",
                        defaultValue: "List",
                        bundle: .module
                    ),
                    systemImage: "list.bullet"
                )
                .tag(ViewMode.list)

                Label(
                    String(
                        localized: "terminal.artifact.gallery.view_mode.grid",
                        defaultValue: "Icons",
                        bundle: .module
                    ),
                    systemImage: "square.grid.2x2"
                )
                .tag(ViewMode.grid)
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: viewMode == .list ? "list.bullet" : "square.grid.2x2")
                .accessibilityLabel(String(
                    localized: "terminal.artifact.gallery.view_mode",
                    defaultValue: "View",
                    bundle: .module
                ))
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        switch scope {
        case .inView:
            inViewContent
        case .session:
            if sessionID == nil {
                inViewContent
            } else {
                sessionContent
                    .searchable(
                        text: $searchQuery,
                        prompt: String(
                            localized: "terminal.artifact.gallery.search",
                            defaultValue: "Search session files",
                            bundle: .module
                        )
                    )
                    .task(id: searchQuery) {
                        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !query.isEmpty else { return }
                        // A cancellable delay is the intended search debounce.
                        try? await ContinuousClock().sleep(for: .milliseconds(300))
                        guard !Task.isCancelled, query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else {
                            return
                        }
                        await loadFirstSessionPage(query: query)
                    }
            }
        }
    }

    @ViewBuilder
    private var inViewContent: some View {
        switch inViewState {
        case .loading:
            loadingView
        case .loaded(let artifacts):
            if artifacts.isEmpty {
                ContentUnavailableView(
                    String(
                        localized: "terminal.artifact.gallery.empty",
                        defaultValue: "No files in view",
                        bundle: .module
                    ),
                    systemImage: "tray"
                )
            } else {
                artifactCollection(
                    artifacts.map(TerminalArtifactGalleryDisplayItem.init(reference:)),
                    loader: loader,
                    scope: .inView
                )
                .refreshable { await refreshInView() }
            }
        case .failed:
            failureView { await refreshInView() }
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            sessionSectionedContent(state: sessionState)
        } else {
            sessionSearchContent(state: searchState, query: query)
        }
    }

    @ViewBuilder
    private func sessionSectionedContent(state: SessionLoadState) -> some View {
        switch state {
        case .idle, .loading:
            loadingView
        case .failed:
            failureView { await loadFirstSessionPage(query: nil) }
        case .loaded(let snapshot):
            if snapshot.isEmpty {
                ScrollView {
                    ContentUnavailableView(
                        String(
                            localized: "terminal.artifact.gallery.session_empty",
                            defaultValue: "No files in this session",
                            bundle: .module
                        ),
                        systemImage: "tray"
                    )
                    .frame(maxWidth: .infinity)
                }
                .refreshable {
                    await loadFirstSessionPage(query: nil, preservingContent: true)
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        artifactSection(
                            title: String(
                                localized: "terminal.artifact.gallery.section.created",
                                defaultValue: "Created by agent",
                                bundle: .module
                            ),
                            count: snapshot.created.count,
                            items: snapshot.created,
                            expanded: $createdExpanded
                        )
                        artifactSection(
                            title: String(
                                localized: "terminal.artifact.gallery.section.attached",
                                defaultValue: "You attached",
                                bundle: .module
                            ),
                            count: snapshot.attached.count,
                            items: snapshot.attached,
                            expanded: $attachedExpanded
                        )
                        artifactSection(
                            title: String(
                                localized: "terminal.artifact.gallery.section.referenced",
                                defaultValue: "Referenced",
                                bundle: .module
                            ),
                            count: snapshot.referencedTotal,
                            items: snapshot.referenced,
                            expanded: $referencedExpanded,
                            pagingCursor: snapshot.nextCursor
                        )
                    }
                }
                .refreshable {
                    await loadFirstSessionPage(query: nil, preservingContent: true)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionSearchContent(state: SessionLoadState, query: String) -> some View {
        switch state {
        case .idle, .loading:
            loadingView
        case .failed:
            failureView { await loadFirstSessionPage(query: query) }
        case .loaded(let snapshot):
            if snapshot.referenced.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    if viewMode == .list {
                        LazyVStack(spacing: 0) {
                            ForEach(snapshot.referenced) { item in
                                TerminalArtifactGalleryItemView(
                                    artifact: TerminalArtifactGalleryDisplayItem(
                                        galleryItem: item,
                                        subtitle: searchSubtitle(for: item)
                                    ),
                                    layout: .list,
                                    loader: sessionLoader,
                                    open: { open(item.path, scope: .session) }
                                )
                                Divider().padding(.leading, 72)
                            }
                            if let cursor = snapshot.nextCursor {
                                pagingFooter(cursor: cursor, query: query)
                            }
                        }
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 16) {
                            Section {
                                ForEach(snapshot.referenced) { item in
                                    TerminalArtifactGalleryItemView(
                                        artifact: TerminalArtifactGalleryDisplayItem(
                                            galleryItem: item,
                                            subtitle: searchSubtitle(for: item)
                                        ),
                                        layout: .grid,
                                        loader: sessionLoader,
                                        open: { open(item.path, scope: .session) }
                                    )
                                }
                            } footer: {
                                if let cursor = snapshot.nextCursor {
                                    pagingFooter(cursor: cursor, query: query)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .refreshable {
                    await loadFirstSessionPage(query: query, preservingContent: true)
                }
            }
        }
    }

    private func artifactSection(
        title: String,
        count: Int,
        items: [ChatArtifactGalleryItem],
        expanded: Binding<Bool>,
        pagingCursor: String? = nil
    ) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            if viewMode == .list {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        TerminalArtifactGalleryItemView(
                            artifact: TerminalArtifactGalleryDisplayItem(galleryItem: item),
                            layout: .list,
                            loader: sessionLoader,
                            open: { open(item.path, scope: .session) }
                        )
                        Divider().padding(.leading, 72)
                    }
                    if let pagingCursor {
                        pagingFooter(cursor: pagingCursor, query: nil)
                    }
                }
            } else {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    Section {
                        ForEach(items) { item in
                            TerminalArtifactGalleryItemView(
                                artifact: TerminalArtifactGalleryDisplayItem(galleryItem: item),
                                layout: .grid,
                                loader: sessionLoader,
                                open: { open(item.path, scope: .session) }
                            )
                        }
                    } footer: {
                        if let pagingCursor {
                            pagingFooter(cursor: pagingCursor, query: nil)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        } label: {
            Text(verbatim: "\(title) (\(count))")
                .font(.headline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func artifactCollection(
        _ artifacts: [TerminalArtifactGalleryDisplayItem],
        loader: ChatArtifactLoader,
        scope: Scope
    ) -> some View {
        switch viewMode {
        case .list:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(artifacts) { artifact in
                        TerminalArtifactGalleryItemView(
                            artifact: artifact,
                            layout: .list,
                            loader: loader,
                            open: { open(artifact.path, scope: scope) }
                        )
                        Divider().padding(.leading, 72)
                    }
                }
            }
        case .grid:
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(artifacts) { artifact in
                        TerminalArtifactGalleryItemView(
                            artifact: artifact,
                            layout: .grid,
                            loader: loader,
                            open: { open(artifact.path, scope: scope) }
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private func pagingFooter(cursor: String, query: String?) -> some View {
        ProgressView(String(
            localized: "terminal.artifact.gallery.loading_more",
            defaultValue: "Loading more…",
            bundle: .module
        ))
        .frame(maxWidth: .infinity)
        .padding()
        .task(id: "\(cursor)#\(query ?? "")") {
            await loadNextSessionPage(cursor: cursor, query: query)
        }
    }

    private var loadingView: some View {
        ProgressView(String(
            localized: "terminal.artifact.gallery.loading",
            defaultValue: "Loading files…",
            bundle: .module
        ))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(retry: @escaping @MainActor () async -> Void) -> some View {
        ContentUnavailableView {
            Label(
                String(
                    localized: "terminal.artifact.gallery.unreachable.title",
                    defaultValue: "Mac unreachable",
                    bundle: .module
                ),
                systemImage: "wifi.exclamationmark"
            )
        } description: {
            Text(String(
                localized: "terminal.artifact.gallery.unreachable.message",
                defaultValue: "Check the connection to your Mac and try again.",
                bundle: .module
            ))
        } actions: {
            Button {
                Task { await retry() }
            } label: {
                Label(
                    String(
                        localized: "terminal.artifact.gallery.retry",
                        defaultValue: "Retry",
                        bundle: .module
                    ),
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 96), spacing: 12)]
    }

    private func searchSubtitle(for item: ChatArtifactGalleryItem) -> String {
        let provenance: String
        switch item.provenance {
        case .created:
            provenance = String(
                localized: "terminal.artifact.gallery.provenance.created",
                defaultValue: "Created",
                bundle: .module
            )
        case .attached:
            provenance = String(
                localized: "terminal.artifact.gallery.provenance.attached",
                defaultValue: "Attached",
                bundle: .module
            )
        case .referenced:
            provenance = String(
                localized: "terminal.artifact.gallery.provenance.referenced",
                defaultValue: "Referenced",
                bundle: .module
            )
        }
        guard let modifiedAt = item.modifiedAt else { return provenance }
        return "\(provenance) · \(modifiedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    private func open(_ path: String, scope: Scope) {
        selection = TerminalArtifactPathSelection(path: path, scope: scope)
    }

    private func loadInitial() async {
        guard let source else {
            inViewState = .failed
            scope = .inView
            return
        }
        inViewState = .loading
        do {
            let response = try await source.terminalArtifactScan(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                visibleOnly: true
            )
            guard !Task.isCancelled else { return }
            let files = response.artifacts.filter { $0.kind != .directory }
            inViewState = .loaded(files)
            guard source.supportsArtifactGallery,
                  let resolvedSessionID = response.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !resolvedSessionID.isEmpty else {
                sessionID = nil
                scope = .inView
                return
            }
            sessionID = resolvedSessionID
            sessionLoader = ChatArtifactLoader(source: source, sessionID: resolvedSessionID)
            scope = .session
            await loadFirstSessionPage(query: nil)
        } catch is CancellationError {
            return
        } catch {
            inViewState = .failed
            scope = .inView
        }
    }

    private func refreshInView() async {
        guard let source else {
            inViewState = .failed
            return
        }
        do {
            let response = try await source.terminalArtifactScan(
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                visibleOnly: true
            )
            guard !Task.isCancelled else { return }
            inViewState = .loaded(response.artifacts.filter { $0.kind != .directory })
        } catch is CancellationError {
            return
        } catch {
            inViewState = .failed
        }
    }

    private func loadFirstSessionPage(
        query: String?,
        preservingContent: Bool = false
    ) async {
        guard let source, let sessionID else { return }
        if !preservingContent {
            if query == nil {
                sessionState = .loading
            } else {
                searchState = .loading
            }
        }
        do {
            let page = try await source.chatArtifactGallery(
                sessionID: sessionID,
                cursor: nil,
                pageSize: Self.pageSize,
                query: query
            )
            guard !Task.isCancelled else { return }
            let snapshot = SessionGallerySnapshot(page: page)
            if let query {
                guard query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                searchState = .loaded(snapshot)
            } else {
                sessionState = .loaded(snapshot)
            }
            startThumbnailPrefetch(page.referenced)
        } catch is CancellationError {
            return
        } catch {
            if !preservingContent {
                if query == nil {
                    sessionState = .failed
                } else {
                    searchState = .failed
                }
            }
        }
    }

    private func loadNextSessionPage(cursor: String, query: String?) async {
        guard let source, let sessionID else { return }
        do {
            let page = try await source.chatArtifactGallery(
                sessionID: sessionID,
                cursor: cursor,
                pageSize: Self.pageSize,
                query: query
            )
            guard !Task.isCancelled else { return }
            if let query {
                guard query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                      case .loaded(let current) = searchState,
                      current.nextCursor == cursor else { return }
                searchState = .loaded(current.appending(page))
            } else {
                guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      case .loaded(let current) = sessionState,
                      current.nextCursor == cursor else { return }
                sessionState = .loaded(current.appending(page))
            }
            startThumbnailPrefetch(page.referenced)
        } catch is CancellationError {
            return
        } catch {
            // Keep already-rendered rows and cursor stable; the footer can retry
            // when SwiftUI recreates it after an explicit refresh or scope change.
        }
    }

    private func startThumbnailPrefetch(_ items: [ChatArtifactGalleryItem]) {
        let loader = sessionLoader
        let task = Task(priority: .low) {
            await withTaskGroup(of: Void.self) { group in
                for item in items where item.kind == .image && item.exists {
                    group.addTask(priority: .low) {
                        _ = try? await loader.thumbnail(
                            path: item.path,
                            maxDimension: 256,
                            modifiedAt: item.modifiedAt,
                            size: item.size
                        )
                    }
                }
            }
        }
        thumbnailPrefetchTasks.append(task)
    }

    private static let pageSize = 60

    private enum InViewLoadState: Equatable {
        case loading
        case loaded([TerminalArtifactReference])
        case failed
    }

    private enum SessionLoadState: Equatable {
        case idle
        case loading
        case loaded(SessionGallerySnapshot)
        case failed
    }

    private struct SessionGallerySnapshot: Equatable {
        let created: [ChatArtifactGalleryItem]
        let attached: [ChatArtifactGalleryItem]
        let referenced: [ChatArtifactGalleryItem]
        let referencedTotal: Int
        let nextCursor: String?
        let generation: String

        var isEmpty: Bool {
            created.isEmpty && attached.isEmpty && referencedTotal == 0
        }

        init(page: ChatArtifactGalleryPage) {
            created = page.created
            attached = page.attached
            referenced = page.referenced
            referencedTotal = page.referencedTotal
            nextCursor = page.nextCursor
            generation = page.generation
        }

        func appending(_ page: ChatArtifactGalleryPage) -> SessionGallerySnapshot {
            SessionGallerySnapshot(
                created: created,
                attached: attached,
                referenced: referenced + page.referenced,
                referencedTotal: page.referencedTotal,
                nextCursor: page.nextCursor,
                generation: page.generation
            )
        }

        private init(
            created: [ChatArtifactGalleryItem],
            attached: [ChatArtifactGalleryItem],
            referenced: [ChatArtifactGalleryItem],
            referencedTotal: Int,
            nextCursor: String?,
            generation: String
        ) {
            self.created = created
            self.attached = attached
            self.referenced = referenced
            self.referencedTotal = referencedTotal
            self.nextCursor = nextCursor
            self.generation = generation
        }
    }

    private enum Scope: Hashable {
        case inView
        case session
    }

    private enum ViewMode: Hashable {
        case list
        case grid
    }

    private struct TerminalArtifactPathSelection: Identifiable {
        let path: String
        let scope: Scope
        var id: String { "\(scope)#\(path)" }
    }
}
#endif
