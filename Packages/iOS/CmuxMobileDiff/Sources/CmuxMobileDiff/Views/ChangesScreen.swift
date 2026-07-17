public import CmuxMobileRPC
public import Foundation
public import SwiftUI

/// Embeddable native workspace changes screen with adaptive navigation shells.
public struct ChangesScreen: View {
    @State private var model: ChangesViewModel
    @State private var scrollAnchorID: String?
    @State private var phoneShowsDiff = false
    @State private var drawerDetent: DiffDrawerDetent = .collapsed
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var activeLayoutPreference: DiffLayoutPreference
    @State private var noteContext: DiffNoteContext?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private let navigationModel: DiffNavigationModel
    private let layoutPreference: DiffLayoutPreference
    private let persistLayoutPreference: @MainActor @Sendable (DiffLayoutPreference) -> Void
    private let sendToAgent: (@MainActor (String) async throws -> Void)?
    private let editInComposer: (@MainActor (String) -> Void)?

    /// Creates a live native changes screen.
    /// - Parameters:
    ///   - service: Workspace-bound changes service.
    ///   - workspace: Workspace context for local preferences.
    ///   - baseSpec: Requested Git comparison base.
    ///   - scrollToPath: Optional file path to reveal after loading.
    ///   - navigationModel: Compact-width files-first or diff-first composition.
    ///   - layoutPreference: Automatic or forced unified/split row layout.
    ///   - setLayoutPreference: Persistence callback for overflow-menu changes.
    ///   - defaults: Injected device-local defaults.
    ///   - sendToAgent: Existing workspace-chat send path, when an agent session is available.
    ///   - editInComposer: Prefills and opens the existing workspace chat composer.
    public init(
        service: any MobileChangesLoading,
        workspace: ChangesWorkspaceContext,
        baseSpec: MobileChangesBaseSpec = MobileChangesBaseSpec(kind: .workingTree),
        scrollToPath: String? = nil,
        navigationModel: DiffNavigationModel = .filesFirst,
        layoutPreference: DiffLayoutPreference = .automatic,
        setLayoutPreference: @escaping @MainActor @Sendable (DiffLayoutPreference) -> Void = { _ in },
        defaults: UserDefaults = .standard,
        sendToAgent: (@MainActor (String) async throws -> Void)? = nil,
        editInComposer: (@MainActor (String) -> Void)? = nil
    ) {
        _model = State(initialValue: ChangesViewModel(
            service: service,
            workspace: workspace,
            baseSpec: baseSpec,
            defaults: defaults
        ))
        _scrollAnchorID = State(initialValue: scrollToPath)
        _activeLayoutPreference = State(initialValue: layoutPreference)
        _noteContext = State(initialValue: nil)
        self.navigationModel = navigationModel
        self.layoutPreference = layoutPreference
        persistLayoutPreference = setLayoutPreference
        self.sendToAgent = sendToAgent
        self.editInComposer = editInComposer
    }

    /// The live, continuously scrolling changed-files surface.
    public var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularWidthShell
            } else if navigationModel == .filesFirst {
                filesFirstShell
            } else {
                diffFirstShell
            }
        }
        .navigationTitle(String(localized: "diff.navigation.title", defaultValue: "Changes", bundle: .module))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            model.setHighlightScheme(scheme == .dark ? .dark : .light)
        }
        .onChange(of: layoutPreference) { _, preference in
            activeLayoutPreference = preference
        }
        .onChange(of: navigationModel) { _, model in
            if model == .diffFirst { phoneShowsDiff = false }
        }
        .onDisappear { model.cancelTransientWork() }
        .sheet(item: $noteContext) { context in
            DiffQuickNoteSheet(
                context: context,
                sendToAgent: sendToAgent,
                editInComposer: editInComposer
            )
        }
    }

    private var filesFirstShell: some View {
        ChangesFileTreeView(
            snapshot: model.snapshot,
            actions: model.actions,
            layoutPreference: activeLayoutPreference,
            setLayoutPreference: setLayoutPreference,
            selectFile: selectFileFromTree
        )
        .navigationDestination(isPresented: $phoneShowsDiff) {
            diffView
                .navigationTitle(String(localized: "diff.navigation.title", defaultValue: "Changes", bundle: .module))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
    }

    private var diffFirstShell: some View {
        ZStack(alignment: .bottom) {
            diffView
                .safeAreaPadding(.bottom, 48)
            DiffFileDrawer(
                snapshot: model.snapshot,
                actions: model.actions,
                layoutPreference: activeLayoutPreference,
                setLayoutPreference: setLayoutPreference,
                selectFile: selectFileFromDrawer,
                detent: $drawerDetent
            )
        }
    }

    private var regularWidthShell: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            ChangesFileTreeView(
                snapshot: model.snapshot,
                actions: model.actions,
                layoutPreference: activeLayoutPreference,
                setLayoutPreference: setLayoutPreference,
                selectFile: revealFile
            )
            .navigationTitle(String(localized: "diff.navigation.files", defaultValue: "Files", bundle: .module))
        } detail: {
            diffView
                .navigationTitle(String(localized: "diff.navigation.title", defaultValue: "Changes", bundle: .module))
        }
    }

    private var diffView: some View {
        ChangesListView(
            snapshot: model.snapshot,
            actions: model.actions,
            renderingMode: renderingMode,
            layoutPreference: activeLayoutPreference,
            setLayoutPreference: setLayoutPreference,
            scrollAnchorID: $scrollAnchorID,
            requestNote: noteEntryPointsAvailable ? requestNote : nil
        )
    }

    private var renderingMode: DiffRenderingMode {
        activeLayoutPreference.resolved(
            isPhoneLandscape: horizontalSizeClass == .compact && verticalSizeClass == .compact
        )
    }

    private func setLayoutPreference(_ preference: DiffLayoutPreference) {
        activeLayoutPreference = preference
        persistLayoutPreference(preference)
    }

    private func revealFile(_ path: String) {
        scrollAnchorID = path
    }

    private func selectFileFromTree(_ path: String) {
        revealFile(path)
        phoneShowsDiff = true
    }

    private func selectFileFromDrawer(_ path: String) {
        revealFile(path)
        withAnimation(.snappy) { drawerDetent = .collapsed }
    }

    private var noteEntryPointsAvailable: Bool {
        sendToAgent != nil || editInComposer != nil
    }

    private func requestNote(
        file: DiffFileSnapshot,
        row: DiffRowSnapshot,
        scope: DiffNoteSelectionScope
    ) {
        noteContext = DiffNoteContextBuilder().context(
            file: file,
            presentedRow: row,
            scope: scope
        )
    }
}
