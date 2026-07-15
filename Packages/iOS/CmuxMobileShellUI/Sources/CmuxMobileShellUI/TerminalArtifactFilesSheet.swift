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

    @State var inViewState: InViewLoadState = .loading
    @State var sessionState: SessionLoadState = .idle
    @State var searchState: SessionLoadState = .idle
    @State var sessionID: String?
    @State var sessionLoader = ChatArtifactLoader.unsupported()
    @State var scope: Scope = .session
    @State var viewMode: ViewMode = .list
    @State var searchQuery = ""
    @State var selection: TerminalArtifactPathSelection?
    @State var createdExpanded = true
    @State var attachedExpanded = true
    @State var referencedExpanded = true
    @State var thumbnailPrefetchTasks: [Task<Void, Never>] = []
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
            inViewState = .loaded(response.artifacts.filter { $0.kind != .directory })
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

    static let pageSize = 60

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

    struct SessionGallerySnapshot: Equatable {
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

    enum Scope: Hashable {
        case inView
        case session
    }

    enum ViewMode: Hashable {
        case list
        case grid
    }

    struct TerminalArtifactPathSelection: Identifiable {
        let path: String
        let scope: Scope
        var id: String { "\(scope)#\(path)" }
    }
}
#endif
