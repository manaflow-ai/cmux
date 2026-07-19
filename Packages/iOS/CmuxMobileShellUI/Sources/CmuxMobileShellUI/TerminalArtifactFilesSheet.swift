#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShell
import Foundation
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
    let sessionID: String?

    init(
        workspaceID: String,
        surfaceID: String,
        path: String,
        session: ChatSessionDescriptor?
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID

        if (path as NSString).isAbsolutePath {
            self.path = (path as NSString).standardizingPath
            sessionID = session?.id
        } else if let session,
                  let workingDirectory = session.workingDirectory,
                  (workingDirectory as NSString).isAbsolutePath {
            self.path = ((workingDirectory as NSString).appendingPathComponent(path) as NSString)
                .standardizingPath
            sessionID = session.id
        } else {
            self.path = path
            sessionID = nil
        }
    }

    var usesSessionAuthorization: Bool { sessionID != nil }

    var id: String { "\(workspaceID)#\(surfaceID)#\(sessionID ?? "terminal")#\(path)" }
}

struct TerminalArtifactFilesSheet: View {
    let workspaceID: String
    let surfaceID: String
    let source: MobileChatEventSource?
    let refreshSignal: TerminalArtifactGalleryRefreshSignal
    let loader: ChatArtifactLoader

    @State var inViewState: InViewLoadState = .loading
    @State var sessionState: SessionLoadState = .idle
    @State var searchState: SessionLoadState = .idle
    @State var sessionID: String?
    @State var sessionLoader = ChatArtifactLoader.unsupported()
    @State var scope: Scope = .session
    @State var viewMode: ViewMode = .list
    @State var galleryFilter: ChatArtifactGalleryFilter = .all
    @State var gallerySort: ChatArtifactGallerySort = .recent
    @State var eagerPagingState: EagerPagingState = .idle
    @State var eagerPagingRetryGeneration = 0
    @State var eagerPagingRevision = 0
    @State var searchQuery = ""
    @State var selection: TerminalArtifactPathSelection?
    @State var createdExpanded = true
    @State var attachedExpanded = true
    @State var referencedExpanded = true
    @State var thumbnailPrefetchTasks: [Task<Void, Never>] = []
    @State var liveRefreshState = ChatArtifactGalleryLiveRefreshState()
    @State var sessionViewportIsAtTopOrFits = true
    @State var lastHandledRefreshSignal: TerminalArtifactGalleryRefreshSignal
    @Environment(MobileDisplaySettings.self) var displaySettings
    @Environment(\.dismiss) private var dismiss

    init(
        workspaceID: String,
        surfaceID: String,
        source: MobileChatEventSource?,
        refreshSignal: TerminalArtifactGalleryRefreshSignal,
        loader: ChatArtifactLoader
    ) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.source = source
        self.refreshSignal = refreshSignal
        self.loader = loader
        _lastHandledRefreshSignal = State(initialValue: refreshSignal)
    }

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
            .navigationDestination(isPresented: artifactIsPresented) {
                if let selection {
                    ChatArtifactViewerDestination(
                        path: selection.path,
                        scope: selection.usesSessionAuthorization ? .chat : .terminal,
                        swipeOrder: selection.swipeOrder
                    ) {
                        dismiss()
                    }
                    .environment(
                        \.chatArtifactLoader,
                        selection.usesSessionAuthorization ? sessionLoader : loader
                    )
                }
            }
        }
        .frame(idealWidth: 380, idealHeight: 520)
        .task(id: "\(workspaceID)#\(surfaceID)") {
            await loadInitial()
        }
        .task(id: liveRefreshTaskID) {
            await refreshSessionForLiveSignal()
        }
        .onDisappear {
            thumbnailPrefetchTasks.forEach { $0.cancel() }
            thumbnailPrefetchTasks.removeAll()
        }
    }

    private var artifactIsPresented: Binding<Bool> {
        Binding(
            get: { selection != nil },
            set: { isPresented in
                if !isPresented { selection = nil }
            }
        )
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
            let files = source.supportsTerminalArtifactList
                ? response.artifacts
                : response.artifacts.filter { $0.kind != .directory }
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

    func refreshInView() async {
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
            let files = source.supportsTerminalArtifactList
                ? response.artifacts
                : response.artifacts.filter { $0.kind != .directory }
            inViewState = .loaded(files)
        } catch is CancellationError {
            return
        } catch {
            inViewState = .failed
        }
    }

    func loadFirstSessionPage(
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
                liveRefreshState.reset()
                sessionState = .loaded(snapshot)
            }
            eagerPagingRevision += 1
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

    func refreshSessionForLiveSignal() async {
        guard refreshSignal != lastHandledRefreshSignal,
              scope == .session,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let source,
              let sessionID,
              case .loaded(let displayed) = sessionState else { return }
        do {
            let page = try await source.chatArtifactGallery(
                sessionID: sessionID,
                cursor: nil,
                pageSize: Self.pageSize,
                query: nil
            )
            guard !Task.isCancelled else { return }
            let fresh = SessionGallerySnapshot(page: page)
            lastHandledRefreshSignal = refreshSignal
            if let reconciled = liveRefreshState.receive(
                fresh: fresh,
                displayed: displayed,
                isAtTopOrFits: sessionViewportIsAtTopOrFits
            ) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    sessionState = .loaded(reconciled)
                }
            }
            let displayedPaths = Set((displayed.created + displayed.attached + displayed.referenced).map(\.path))
            startThumbnailPrefetch(
                (fresh.created + fresh.attached + fresh.referenced).filter {
                    !displayedPaths.contains($0.path)
                }
            )
        } catch is CancellationError {
            return
        } catch {
            // Keep the current gallery stable. The next accepted chip signal
            // retries against a newer terminal/session generation.
        }
    }

    func loadNextSessionPage(cursor: String, query: String?) async {
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
                if page.requiresPagingRestart {
                    await restartPaging(after: cursor, query: query)
                    return
                }
                searchState = .loaded(current.appending(page))
            } else {
                guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      case .loaded(let current) = sessionState,
                      current.nextCursor == cursor else { return }
                if page.requiresPagingRestart {
                    await restartPaging(after: cursor, query: nil)
                    return
                }
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

    func loadRemainingSessionPages(query: String?) async {
        guard let source, let sessionID, usesCompleteSessionSnapshot else {
            eagerPagingState = .idle
            return
        }
        let initialState = query == nil ? sessionState : searchState
        guard case .loaded(let initialSnapshot) = initialState else {
            eagerPagingState = .idle
            return
        }
        guard initialSnapshot.nextCursor != nil else {
            eagerPagingState = initialSnapshot.referenced.count
                < initialSnapshot.referencedTotal ? .capped : .idle
            return
        }

        let expectedFilter = galleryFilter
        let expectedSort = gallerySort
        let expectedShowMissingFiles = displaySettings.showMissingFiles
        let expectedQuery = query
        eagerPagingState = .loading
        do {
            let result = try await ChatArtifactGalleryEagerPager().loadRemaining(
                from: initialSnapshot
            ) { cursor in
                try await source.chatArtifactGallery(
                    sessionID: sessionID,
                    cursor: cursor,
                    pageSize: Self.pageSize,
                    query: expectedQuery
                )
            }
            if result.requiresPagingRestart {
                await restartPaging(
                    after: initialSnapshot.nextCursor,
                    query: expectedQuery
                )
                return
            }
            let currentQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let queryIsCurrent = expectedQuery.map { $0 == currentQuery }
                ?? currentQuery.isEmpty
            guard !Task.isCancelled,
                  galleryFilter == expectedFilter,
                  gallerySort == expectedSort,
                  displaySettings.showMissingFiles == expectedShowMissingFiles,
                  queryIsCurrent else { return }
            let currentState = query == nil ? sessionState : searchState
            guard case .loaded(let currentSnapshot) = currentState,
                  currentSnapshot.generation == initialSnapshot.generation,
                  currentSnapshot.nextCursor == initialSnapshot.nextCursor else { return }
            if query == nil {
                sessionState = .loaded(result.snapshot)
            } else {
                searchState = .loaded(result.snapshot)
            }
            let previousPaths = Set(initialSnapshot.referenced.map(\.path))
            startThumbnailPrefetch(
                result.snapshot.referenced.filter { !previousPaths.contains($0.path) }
            )
            if result.reachedSafetyCap {
                eagerPagingState = .capped
            } else if result.snapshot.nextCursor != nil {
                // A defensive cursor-loop stop is incomplete, so surface the
                // existing retry affordance instead of presenting partial
                // transformed results as complete.
                eagerPagingState = .failed
            } else {
                eagerPagingState = .idle
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            eagerPagingState = .failed
        }
    }

    private func restartPaging(after staleCursor: String?, query: String?) async {
        guard let staleCursor, let source, let sessionID else { return }
        let currentQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.map({ $0 == currentQuery }) ?? currentQuery.isEmpty else { return }
        let state = query == nil ? sessionState : searchState
        guard case .loaded(let displayed) = state,
              displayed.nextCursor == staleCursor else { return }
        do {
            let page = try await source.chatArtifactGallery(
                sessionID: sessionID,
                cursor: nil,
                pageSize: Self.pageSize,
                query: query
            )
            guard !Task.isCancelled else { return }
            let currentState = query == nil ? sessionState : searchState
            guard case .loaded(let current) = currentState,
                  current.nextCursor == staleCursor else { return }
            let fresh = SessionGallerySnapshot(page: page)
            if query == nil {
                if sessionViewportIsAtTopOrFits {
                    liveRefreshState.reset()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        sessionState = .loaded(current.reconciling(withFreshFirstPage: fresh))
                    }
                } else {
                    _ = liveRefreshState.receive(
                        fresh: fresh,
                        displayed: current,
                        isAtTopOrFits: false
                    )
                    sessionState = .loaded(current.rebasingPaging(ontoFreshFirstPage: fresh))
                }
            } else {
                searchState = .loaded(current.restartingPaging(withFreshFirstPage: fresh))
            }
            eagerPagingState = .idle
            eagerPagingRevision += 1
            let currentPaths = Set((current.created + current.attached + current.referenced).map(\.path))
            startThumbnailPrefetch(
                (fresh.created + fresh.attached + fresh.referenced).filter {
                    !currentPaths.contains($0.path)
                }
            )
        } catch is CancellationError {
            return
        } catch {
            eagerPagingState = .failed
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

    static let pageSize = 60

    var usesCompleteSessionSnapshot: Bool {
        galleryFilter != .all
            || gallerySort != .recent
            || !displaySettings.showMissingFiles
    }

    var eagerPagingTaskID: String {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = query.isEmpty ? sessionState : searchState
        let cursor: String
        if case .loaded(let snapshot) = state {
            cursor = "\(snapshot.generation)#\(snapshot.nextCursor ?? "exhausted")"
        } else {
            cursor = "unloaded"
        }
        return [
            galleryFilter.rawValue,
            gallerySort.rawValue,
            String(displaySettings.showMissingFiles),
            query,
            cursor,
            String(eagerPagingRevision),
            String(eagerPagingRetryGeneration),
        ].joined(separator: "#")
    }

    var liveRefreshTaskID: String {
        [
            String(refreshSignal.surfaceGeneration),
            String(refreshSignal.count),
            sessionID ?? "unresolved",
            String(describing: scope),
            searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "#")
    }

    enum InViewLoadState: Equatable {
        case loading
        case loaded([TerminalArtifactReference])
        case failed
    }

    enum SessionLoadState: Equatable {
        case idle
        case loading
        case loaded(SessionGallerySnapshot)
        case failed
    }

    typealias SessionGallerySnapshot = ChatArtifactGallerySnapshot

    enum Scope: Hashable {
        case inView
        case session
    }

    enum ViewMode: Hashable {
        case list
        case grid
    }

    enum EagerPagingState: Equatable {
        case idle
        case loading
        case capped
        case failed
    }

    struct TerminalArtifactPathSelection: Identifiable {
        let path: String
        let scope: Scope
        let usesSessionAuthorization: Bool
        let swipeOrder: ChatArtifactGallerySwipeOrder
        var id: String { "\(scope)#\(usesSessionAuthorization)#\(path)" }
    }
}
#endif
