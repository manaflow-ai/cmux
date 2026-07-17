#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import SwiftUI

extension TerminalArtifactFilesSheet {
    var scopePicker: some View {
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

    var viewModePicker: some View {
        Button {
            viewMode = viewMode == .list ? .grid : .list
        } label: {
            Image(systemName: viewMode == .list ? "square.grid.3x3" : "list.bullet")
                .accessibilityLabel(viewMode == .list
                    ? String(
                        localized: "terminal.artifact.gallery.view_mode.grid",
                        defaultValue: "Icons",
                        bundle: .module
                    )
                    : String(
                        localized: "terminal.artifact.gallery.view_mode.list",
                        defaultValue: "List",
                        bundle: .module
                    ))
        }
    }

    @ViewBuilder
    var activeContent: some View {
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
                let swipeOrder = ChatArtifactGallerySwipeOrder(references: artifacts)
                artifactCollection(
                    artifacts.map(TerminalArtifactGalleryDisplayItem.init(reference:)),
                    loader: loader,
                    scope: .inView,
                    swipeOrder: swipeOrder
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
        VStack(spacing: 0) {
            galleryControls
            if eagerPagingState == .loading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(String(
                        localized: "terminal.artifact.gallery.loading_all",
                        defaultValue: "Loading all files…",
                        bundle: .module
                    ))
            }
            Divider()
            if query.isEmpty {
                sessionSectionedContent(state: sessionState)
            } else {
                sessionSearchContent(state: searchState, query: query)
            }
        }
        .task(id: eagerPagingTaskID) {
            await loadRemainingSessionPages(query: query.isEmpty ? nil : query)
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
            let visibleSnapshotIsEmpty = displaySettings.showMissingFiles
                ? snapshot.isEmpty
                : ChatArtifactGalleryPresentation(snapshot: snapshot).isEmpty
            let presentation = ChatArtifactGalleryPresentation(
                snapshot: snapshot,
                filter: galleryFilter,
                sort: gallerySort,
                includesMissingFiles: displaySettings.showMissingFiles
            )
            if visibleSnapshotIsEmpty {
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
                let created = presentation.items(in: .created)
                let attached = presentation.items(in: .attached)
                let referenced = presentation.items(in: .referenced)
                let swipeOrder = ChatArtifactGallerySwipeOrder(groups: presentation.groups)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: 0)
                                .id(Self.sessionScrollTopID)
                        artifactSection(
                            title: String(
                                localized: "terminal.artifact.gallery.section.created",
                                defaultValue: "Created by agent",
                                bundle: .module
                            ),
                            count: displaySettings.showMissingFiles
                                ? (usesCompleteSessionSnapshot ? created.count : snapshot.createdTotal)
                                : nil,
                            items: created,
                            expanded: $createdExpanded,
                            swipeOrder: swipeOrder
                        )
                        artifactSection(
                            title: String(
                                localized: "terminal.artifact.gallery.section.attached",
                                defaultValue: "You attached",
                                bundle: .module
                            ),
                            count: displaySettings.showMissingFiles
                                ? (usesCompleteSessionSnapshot ? attached.count : snapshot.attachedTotal)
                                : nil,
                            items: attached,
                            expanded: $attachedExpanded,
                            swipeOrder: swipeOrder
                        )
                        artifactSection(
                            title: String(
                                localized: "terminal.artifact.gallery.section.referenced",
                                defaultValue: "Referenced",
                                bundle: .module
                            ),
                            count: displaySettings.showMissingFiles
                                ? (usesCompleteSessionSnapshot
                                    ? referenced.count
                                    : snapshot.referencedTotal)
                                : nil,
                            items: referenced,
                            expanded: $referencedExpanded,
                            swipeOrder: swipeOrder,
                            pagingCursor: usesCompleteSessionSnapshot ? nil : snapshot.nextCursor,
                            showsEagerFooter: usesCompleteSessionSnapshot
                        )
                    }
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        let isAtTop = geometry.contentOffset.y
                            <= geometry.contentInsets.top + Self.sessionTopTolerance
                        let fits = geometry.contentSize.height
                            <= geometry.containerSize.height + Self.sessionTopTolerance
                        return isAtTop || fits
                    } action: { _, isAtTopOrFits in
                        sessionViewportIsAtTopOrFits = isAtTopOrFits
                    }
                    .overlay(alignment: .top) {
                        if liveRefreshState.pendingNewFileCount > 0 {
                            newFilesPill(snapshot: snapshot, proxy: proxy)
                                .padding(.top, 8)
                        }
                    }
                }
                .refreshable {
                    await loadFirstSessionPage(query: nil, preservingContent: true)
                }
            }
        }
    }

    private func newFilesPill(
        snapshot: SessionGallerySnapshot,
        proxy: ScrollViewProxy
    ) -> some View {
        let format = String(
            localized: "terminal.artifact.gallery.new_files",
            defaultValue: "%lld new files",
            bundle: .module
        )
        let title = String.localizedStringWithFormat(
            format,
            Int64(liveRefreshState.pendingNewFileCount)
        )
        return Button {
            guard let reconciled = liveRefreshState.applyPending(to: snapshot) else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                sessionState = .loaded(reconciled)
                proxy.scrollTo(Self.sessionScrollTopID, anchor: .top)
            }
        } label: {
            Label(title, systemImage: "arrow.up")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func sessionSearchContent(state: SessionLoadState, query: String) -> some View {
        switch state {
        case .idle, .loading:
            loadingView
        case .failed:
            failureView { await loadFirstSessionPage(query: query) }
        case .loaded(let snapshot):
            let presentation = ChatArtifactGalleryPresentation(
                snapshot: snapshot,
                filter: galleryFilter,
                sort: gallerySort,
                includesMissingFiles: displaySettings.showMissingFiles
            )
            let items = presentation.items(in: .referenced)
            let swipeOrder = ChatArtifactGallerySwipeOrder(items: items)
            if items.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    if viewMode == .list {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                TerminalArtifactGalleryItemView(
                                    artifact: TerminalArtifactGalleryDisplayItem(
                                        galleryItem: item,
                                        subtitle: searchSubtitle(for: item)
                                    ),
                                    layout: .list,
                                    loader: sessionLoader,
                                    open: {
                                        open(item.path, scope: .session, swipeOrder: swipeOrder)
                                    }
                                )
                                Divider().padding(.leading, 72)
                            }
                            if !usesCompleteSessionSnapshot,
                               let cursor = snapshot.nextCursor {
                                pagingFooter(cursor: cursor, query: query)
                            } else if usesCompleteSessionSnapshot {
                                eagerPagingFooter
                            }
                        }
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 16) {
                            Section {
                                ForEach(items) { item in
                                    TerminalArtifactGalleryItemView(
                                        artifact: TerminalArtifactGalleryDisplayItem(
                                            galleryItem: item,
                                            subtitle: searchSubtitle(for: item)
                                        ),
                                        layout: .grid,
                                        loader: sessionLoader,
                                        open: {
                                            open(item.path, scope: .session, swipeOrder: swipeOrder)
                                        }
                                    )
                                }
                            } footer: {
                                if !usesCompleteSessionSnapshot,
                                   let cursor = snapshot.nextCursor {
                                    pagingFooter(cursor: cursor, query: query)
                                } else if usesCompleteSessionSnapshot {
                                    eagerPagingFooter
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
        count: Int?,
        items: [ChatArtifactGalleryItem],
        expanded: Binding<Bool>,
        swipeOrder: ChatArtifactGallerySwipeOrder,
        pagingCursor: String? = nil,
        showsEagerFooter: Bool = false
    ) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            if viewMode == .list {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        TerminalArtifactGalleryItemView(
                            artifact: TerminalArtifactGalleryDisplayItem(galleryItem: item),
                            layout: .list,
                            loader: sessionLoader,
                            open: {
                                open(item.path, scope: .session, swipeOrder: swipeOrder)
                            }
                        )
                        Divider().padding(.leading, 72)
                    }
                    if let pagingCursor {
                        pagingFooter(cursor: pagingCursor, query: nil)
                    } else if showsEagerFooter {
                        eagerPagingFooter
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
                                open: {
                                    open(item.path, scope: .session, swipeOrder: swipeOrder)
                                }
                            )
                        }
                    } footer: {
                        if let pagingCursor {
                            pagingFooter(cursor: pagingCursor, query: nil)
                        } else if showsEagerFooter {
                            eagerPagingFooter
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        } label: {
            Text(verbatim: count.map { "\(title) (\($0))" } ?? title)
                .font(.headline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func artifactCollection(
        _ artifacts: [TerminalArtifactGalleryDisplayItem],
        loader: ChatArtifactLoader,
        scope: Scope,
        swipeOrder: ChatArtifactGallerySwipeOrder
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
                            open: {
                                open(artifact.path, scope: scope, swipeOrder: swipeOrder)
                            }
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
                            open: {
                                open(artifact.path, scope: scope, swipeOrder: swipeOrder)
                            }
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

    @ViewBuilder
    private var eagerPagingFooter: some View {
        switch eagerPagingState {
        case .idle, .loading:
            EmptyView()
        case .capped:
            let format = String(
                localized: "terminal.artifact.gallery.showing_first",
                defaultValue: "Showing first %lld files",
                bundle: .module
            )
            Text(String.localizedStringWithFormat(
                format,
                Int64(ChatArtifactGalleryEagerPager.defaultMaximumReferencedRows)
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding()
        case .failed:
            Button {
                eagerPagingRetryGeneration += 1
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
            .frame(maxWidth: .infinity)
            .padding()
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
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
            count: 3
        )
    }

    private static let sessionScrollTopID = "terminal-artifact-gallery-top"
    private static let sessionTopTolerance: CGFloat = 1

    private var galleryControls: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ChatArtifactGalleryFilter.allCases, id: \.self) { filter in
                        Button {
                            galleryFilter = filter
                        } label: {
                            Text(filterTitle(filter))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(galleryFilter == filter ? Color.white : Color.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    galleryFilter == filter
                                        ? Color.accentColor
                                        : Color(uiColor: .secondarySystemBackground),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(galleryFilter == filter ? .isSelected : [])
                    }
                }
            }

            Menu {
                Picker(
                    String(
                        localized: "terminal.artifact.gallery.sort",
                        defaultValue: "Sort",
                        bundle: .module
                    ),
                    selection: $gallerySort
                ) {
                    ForEach(ChatArtifactGallerySort.allCases, id: \.self) { sort in
                        Text(sortTitle(sort)).tag(sort)
                    }
                }
            } label: {
                Label(sortTitle(gallerySort), systemImage: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func filterTitle(_ filter: ChatArtifactGalleryFilter) -> String {
        switch filter {
        case .all:
            String(localized: "terminal.artifact.gallery.filter.all", defaultValue: "All", bundle: .module)
        case .images:
            String(localized: "terminal.artifact.gallery.filter.images", defaultValue: "Images", bundle: .module)
        case .code:
            String(localized: "terminal.artifact.gallery.filter.code", defaultValue: "Code", bundle: .module)
        case .logs:
            String(localized: "terminal.artifact.gallery.filter.logs", defaultValue: "Logs", bundle: .module)
        case .docs:
            String(localized: "terminal.artifact.gallery.filter.docs", defaultValue: "Docs", bundle: .module)
        case .folders:
            String(localized: "terminal.artifact.gallery.filter.folders", defaultValue: "Folders", bundle: .module)
        }
    }

    private func sortTitle(_ sort: ChatArtifactGallerySort) -> String {
        switch sort {
        case .recent:
            String(localized: "terminal.artifact.gallery.sort.recent", defaultValue: "Recent", bundle: .module)
        case .name:
            String(localized: "terminal.artifact.gallery.sort.name", defaultValue: "Name", bundle: .module)
        case .size:
            String(localized: "terminal.artifact.gallery.sort.size", defaultValue: "Size", bundle: .module)
        }
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

    private func open(
        _ path: String,
        scope: Scope,
        swipeOrder: ChatArtifactGallerySwipeOrder
    ) {
        selection = TerminalArtifactPathSelection(
            path: path,
            scope: scope,
            usesSessionAuthorization: scope == .session || sessionID != nil,
            swipeOrder: swipeOrder
        )
    }
}
#endif
