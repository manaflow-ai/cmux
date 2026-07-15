public import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Live native diff navigation for iPhone and iPad backed by ``DiffScreenStore``.
public struct DiffLiveScreen: View {
    @State private var store: DiffScreenStore
    @State private var scrollTarget: String?
    @State private var scrollRequestID = 0
    @State private var showingFilesFirstDiff = false
    @State private var showingTreeDrawer = false
    @State private var splitVisibility: NavigationSplitViewVisibility = .all

    private let navigationModel: DiffNavigationModel
    private let highlighter: any CodeHighlighting

    /// Creates a live diff screen around an already-constructed observable store.
    /// - Parameters:
    ///   - store: The screen's service-backed reducer and persisted state.
    ///   - navigationModel: Files-first or diff-first navigation behavior.
    ///   - highlighter: The asynchronous syntax-highlighting implementation.
    public init(
        store: DiffScreenStore,
        navigationModel: DiffNavigationModel = .filesFirst,
        highlighter: any CodeHighlighting = HighlighterSwiftCodeHighlighter()
    ) {
        _store = State(initialValue: store)
        self.navigationModel = navigationModel
        self.highlighter = highlighter
    }

    /// The adaptive loading, failure, phone, and tablet screen hierarchy.
    public var body: some View {
        Group {
            switch store.phase {
            case .idle, .loading:
                DiffLoadingView()
            case let .failed(kind):
                DiffFailureView(kind: kind) {
                    Task { await store.retryBanner() }
                }
            case .loaded:
                loadedNavigation
            }
        }
        .task {
            await store.loadInitial()
        }
    }

    @ViewBuilder private var loadedNavigation: some View {
        if isPad {
            NavigationSplitView(columnVisibility: $splitVisibility) {
                tree
                    .navigationTitle(filesTitle)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 360)
            } detail: {
                diffDetail
            }
            .navigationSplitViewStyle(.balanced)
            .banner(store.errorBanner, retry: retryBanner, dismiss: store.dismissBanner)
        } else {
            switch navigationModel {
            case .filesFirst:
                NavigationStack {
                    tree
                        .navigationTitle(filesTitle)
                        .navigationDestination(isPresented: $showingFilesFirstDiff) {
                            diffDetail
                        }
                }
                .banner(store.errorBanner, retry: retryBanner, dismiss: store.dismissBanner)
            case .diffFirst:
                NavigationStack {
                    diffDetail
                }
                .sheet(isPresented: $showingTreeDrawer) {
                    NavigationStack {
                        tree
                            .navigationTitle(filesTitle)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(doneLabel) { showingTreeDrawer = false }
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
                .banner(store.errorBanner, retry: retryBanner, dismiss: store.dismissBanner)
            }
        }
    }

    private var tree: some View {
        DiffFileTreeView(
            nodes: store.treeNodes,
            files: store.fileStates,
            selectFile: selectFile,
            refresh: store.refresh
        )
    }

    private var diffDetail: some View {
        GeometryReader { geometry in
            let renderMode = store.layoutOverride.renderMode(
                isLandscape: geometry.size.width > geometry.size.height
            )
            DiffContinuousView(
                fileStates: store.fileStates,
                totalFileCount: store.summary?.totals.files ?? store.fileStates.count,
                additions: store.summary?.totals.additions ?? 0,
                deletions: store.summary?.totals.deletions ?? 0,
                baseLabel: store.summary?.baseInfo.describe ?? "",
                renderMode: renderMode,
                scrollTarget: scrollTarget,
                scrollRequestID: scrollRequestID,
                showFileIndex: false,
                highlighter: highlighter,
                actions: continuousActions
            )
        }
        .navigationTitle(changesTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !isPad, navigationModel == .diffFirst {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingTreeDrawer = true
                    } label: {
                        Label(filesTitle, systemImage: "list.bullet.indent")
                    }
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                layoutMenu
            }
        }
    }

    private var layoutMenu: some View {
        Menu {
            Picker(layoutLabel, selection: layoutBinding) {
                Text(automaticLayoutLabel).tag(DiffLayoutOverride.automatic)
                Text(unifiedLayoutLabel).tag(DiffLayoutOverride.unified)
                Text(splitLayoutLabel).tag(DiffLayoutOverride.split)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(moreLabel)
    }

    private var layoutBinding: Binding<DiffLayoutOverride> {
        Binding(
            get: { store.layoutOverride },
            set: { store.layoutOverride = $0 }
        )
    }

    private var continuousActions: DiffContinuousActions {
        DiffContinuousActions(
            loadFile: { path, force in
                Task { await store.loadFile(path: path, force: force) }
            },
            expandContext: { request in
                Task { await store.expandContext(request) }
            },
            toggleViewed: store.toggleViewed,
            toggleCollapsed: store.toggleCollapsed,
            collapseAll: store.collapseAll,
            refresh: store.refresh
        )
    }

    @MainActor private func selectFile(path: String) {
        guard let target = DiffTreeScrollTargetResolver().target(path: path, files: store.files) else {
            return
        }
        scrollTarget = target
        scrollRequestID &+= 1
        if !isPad, navigationModel == .filesFirst {
            showingFilesFirstDiff = true
        }
        showingTreeDrawer = false
        Task { await store.loadFile(path: path) }
    }

    @MainActor private func retryBanner() {
        Task { await store.retryBanner() }
    }

    private var isPad: Bool {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    private var filesTitle: String {
        DiffLocalized().string("diff.files.changedTitle", defaultValue: "Changed files")
    }

    private var changesTitle: String {
        DiffLocalized().string("diff.screen.title", defaultValue: "Changes")
    }

    private var doneLabel: String {
        DiffLocalized().string("diff.action.done", defaultValue: "Done")
    }

    private var layoutLabel: String {
        DiffLocalized().string("diff.mode.label", defaultValue: "Layout")
    }

    private var automaticLayoutLabel: String {
        DiffLocalized().string("diff.mode.automatic", defaultValue: "Automatic")
    }

    private var unifiedLayoutLabel: String {
        DiffLocalized().string("diff.mode.unified", defaultValue: "Unified")
    }

    private var splitLayoutLabel: String {
        DiffLocalized().string("diff.mode.split", defaultValue: "Split")
    }

    private var moreLabel: String {
        DiffLocalized().string("diff.action.more", defaultValue: "More options")
    }
}

private extension View {
    @ViewBuilder
    func banner(
        _ kind: DiffScreenErrorKind?,
        retry: @escaping @MainActor () -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) -> some View {
        if let kind {
            safeAreaInset(edge: .top, spacing: 0) {
                DiffErrorBannerView(kind: kind, retry: retry, dismiss: dismiss)
            }
        } else {
            self
        }
    }
}
