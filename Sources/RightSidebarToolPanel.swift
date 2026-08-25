import AppKit
import Combine
import CmuxAppKitSupportUI
import SwiftUI

@MainActor
final class RightSidebarToolPanel: Panel, ObservableObject {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .rightSidebarTool
    let mode: RightSidebarMode
    let sourcePanelID: UUID?
    let rootDirectory: String?

    @Published private(set) var focusFlashToken: Int = 0

    private weak var workspace: Workspace?
    private weak var fileExplorerContainerView: FileExplorerContainerView?
    private weak var toolFocusAnchorView: RightSidebarToolFocusAnchorView?
    private var fileExplorerStoreStorage: FileExplorerStore?
    private var fileExplorerStateStorage: FileExplorerState?
    private var fileWorkspaceModelStorage: FileWorkspaceModel?
    private var sessionIndexStoreStorage: SessionIndexStore?
    private var gitGraphModelStorage: GitGraphPanelModel?
    private var herdModelStorage: HerdPanelModel?
    private var remoteFileOpenTask: Task<Void, Never>?
    private var workspaceObservationCancellable: AnyCancellable?

    init(
        workspace: Workspace,
        mode: RightSidebarMode,
        sourcePanelID: UUID? = nil,
        rootDirectory: String? = nil
    ) {
        self.id = UUID()
        self.mode = mode
        self.sourcePanelID = sourcePanelID
        self.rootDirectory = rootDirectory
        if mode == .herd {
            self.herdModelStorage = HerdPanelModel()
        }
        reattach(to: workspace)
    }

    deinit {
        remoteFileOpenTask?.cancel()
    }

    var fileExplorerStore: FileExplorerStore {
        if let store = fileExplorerStoreStorage { return store }
        let store = FileExplorerStore()
        store.showHiddenFiles = true
        fileExplorerStoreStorage = store
        if let workspace {
            syncFileExplorerRoot(from: workspace, store: store)
        }
        return store
    }

    var fileExplorerState: FileExplorerState {
        if let state = fileExplorerStateStorage { return state }
        let state = FileExplorerState()
        fileExplorerStateStorage = state
        return state
    }

    var fileWorkspaceModel: FileWorkspaceModel {
        if let model = fileWorkspaceModelStorage { return model }
        let model = FileWorkspaceModel()
        fileWorkspaceModelStorage = model
        return model
    }

    var sessionIndexStore: SessionIndexStore {
        if let store = sessionIndexStoreStorage { return store }
        let store = SessionIndexStore()
        sessionIndexStoreStorage = store
        if let workspace {
            syncSessionIndexRoot(from: workspace, store: store)
        }
        return store
    }

    var gitGraphModel: GitGraphPanelModel {
        if let model = gitGraphModelStorage { return model }
        let model = GitGraphPanelModel()
        gitGraphModelStorage = model
        if let workspace {
            syncGitGraphRoot(from: workspace, model: model)
        }
        return model
    }

    var herdModel: HerdPanelModel {
        guard let model = herdModelStorage else {
            preconditionFailure("Herd model requested for a non-Herd tool panel")
        }
        return model
    }

    var displayTitle: String { mode.label }
    var displayIcon: String? { mode.symbolName }

    func reattach(to workspace: Workspace) {
        self.workspace = workspace
        observeWorkspaceRootChanges(workspace)
        syncWorkspaceRoot(from: workspace)
    }

    func attachFileExplorerContainer(_ container: FileExplorerContainerView?) {
        fileExplorerContainerView = container
    }

    fileprivate func attachToolFocusAnchor(_ anchor: RightSidebarToolFocusAnchorView?) {
        toolFocusAnchorView = anchor
    }

    func syncWorkspaceRoot(from workspace: Workspace) {
        switch mode {
        case .files, .find:
            guard let store = fileExplorerStoreStorage else { return }
            syncFileExplorerRoot(from: workspace, store: store)
        case .sessions:
            guard let store = sessionIndexStoreStorage else { return }
            syncSessionIndexRoot(from: workspace, store: store)
        case .gitGraph:
            guard let model = gitGraphModelStorage else { return }
            syncGitGraphRoot(from: workspace, model: model)
        case .herd, .feed, .dock, .machines, .customSidebar:
            break
        }
    }

    func openFilePreview(_ filePath: String) {
        if mode == .files {
            openFileInWorkspace(filePath)
            return
        }

        guard let workspace,
              let paneId = workspace.paneId(forPanelId: id)
                ?? workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }
        if workspace.isRemoteWorkspace {
            let store = fileExplorerStore
            Task { [weak workspace, weak store] in
                guard let workspace, let store else { return }
                do {
                    let localURL = try await store.materializeRemoteFileForPreview(path: filePath)
                    _ = workspace.openFileSurfaces(
                        inPane: paneId,
                        filePaths: [localURL.path],
                        focus: true,
                        reuseExisting: true
                    )
                } catch {
                    NSSound.beep()
                }
            }
            return
        }
        _ = workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [filePath],
            focus: true,
            reuseExisting: true
        )
    }

    private func openFileInWorkspace(_ filePath: String) {
        guard let workspace else { return }

        remoteFileOpenTask?.cancel()
        remoteFileOpenTask = nil
        fileWorkspaceModel.cancelRemoteFileOpenRequest()

        if workspace.isRemoteWorkspace {
            let store = fileExplorerStore
            let requestID = fileWorkspaceModel.beginRemoteFileOpenRequest()
            remoteFileOpenTask = Task { [weak self, weak workspace, weak store] in
                guard let self, let workspace, let store else { return }
                do {
                    let localURL = try await store.materializeRemoteFileForPreview(path: filePath)
                    guard !Task.isCancelled else { return }
                    self.fileWorkspaceModel.completeRemoteFileOpenRequest(
                        requestID,
                        workspaceID: workspace.id,
                        filePath: localURL.path
                    )
                } catch {
                    guard !Task.isCancelled,
                          self.fileWorkspaceModel.failRemoteFileOpenRequest(requestID) else { return }
                    NSSound.beep()
                }
            }
            return
        }

        fileWorkspaceModel.openFile(workspaceID: workspace.id, filePath: filePath)
    }

    var isFocusedInWorkspace: Bool {
        workspace?.focusedPanelId == id
    }

    func close() {
        remoteFileOpenTask?.cancel()
        remoteFileOpenTask = nil
        fileExplorerContainerView = nil
        toolFocusAnchorView = nil
        fileExplorerStoreStorage?.applyWorkspaceRoot(.none)
        sessionIndexStoreStorage?.setCurrentDirectoryIfChanged(nil)
        fileWorkspaceModelStorage?.close()
        workspaceObservationCancellable = nil
    }

    func focus() {
        switch mode {
        case .files:
            _ = fileExplorerContainerView?.focusOutline()
        case .find:
            _ = fileExplorerContainerView?.focusSearchField()
        case .sessions, .herd:
            guard let anchor = toolFocusAnchorView,
                  let window = anchor.window else { return }
            _ = window.makeFirstResponder(anchor)
        case .gitGraph, .feed, .dock, .machines, .customSidebar:
            break
        }
    }

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = window
        switch mode {
        case .files, .find:
            let explorerOwnsFocus = fileExplorerContainerView?.ownsKeyboardFocus(responder) == true
            let editorOwnsFocus = mode == .files
                && fileWorkspaceModelStorage?.ownsFocus(responder, in: window) == true
            guard explorerOwnsFocus || editorOwnsFocus else { return nil }
            return .panel
        case .sessions, .herd:
            guard toolFocusAnchorView?.ownsKeyboardFocus(responder) == true else { return nil }
            return .panel
        case .gitGraph, .feed, .dock, .machines, .customSidebar:
            return nil
        }
    }

    private func observeWorkspaceRootChanges(_ workspace: Workspace) {
        workspaceObservationCancellable = Publishers.MergeMany(
            workspace.$currentDirectory.map { _ in () }.eraseToAnyPublisher(),
            workspace.$panelDirectories.map { _ in () }.eraseToAnyPublisher(),
            workspace.currentDirectoryChangeRevisionPublisher()
                .map { _ in () }
                .eraseToAnyPublisher(),
            workspace.$activeRemoteTerminalSessionCount.map { _ in () }.eraseToAnyPublisher(),
            workspace.$remoteConfiguration.map { _ in () }.eraseToAnyPublisher(),
            workspace.$remoteConnectionState.map { _ in () }.eraseToAnyPublisher(),
            workspace.$remoteConnectionDetail.map { _ in () }.eraseToAnyPublisher(),
            workspace.$remoteDaemonStatus.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self, weak workspace] _ in
            Task { @MainActor in
                guard let self, let workspace else { return }
                self.syncWorkspaceRoot(from: workspace)
            }
        }
    }

    private func syncFileExplorerRoot(from workspace: Workspace, store: FileExplorerStore) {
        store.showHiddenFiles = true

        if workspace.usesRemoteDirectoryProvenance {
            guard let configuration = workspace.remoteConfiguration,
                  configuration.transport == .ssh else {
                store.applyWorkspaceRoot(.none)
                return
            }
            let unavailableDetail = workspace.remoteConnectionDetail ?? workspace.remoteDaemonStatus.detail
            store.applyWorkspaceRoot(
                .remoteSSH(
                    workspaceId: workspace.id,
                    connection: SSHFileExplorerConnection(
                        destination: configuration.destination,
                        port: configuration.port,
                        identityFile: configuration.identityFile,
                        sshOptions: configuration.sshOptions
                    ),
                    displayTarget: configuration.displayTarget,
                    rootPath: resolvedFileExplorerDirectory(from: workspace),
                    isAvailable: workspace.remoteConnectionState == .connected,
                    unavailableDetail: unavailableDetail
                )
            )
            return
        }

        guard let directory = resolvedFileExplorerDirectory(from: workspace) else {
            store.applyWorkspaceRoot(.none)
            return
        }

        store.applyWorkspaceRoot(.local(workspaceId: workspace.id, path: directory))
    }

    private func resolvedFileExplorerDirectory(from workspace: Workspace) -> String? {
        workspace.repositoryToolDirectory(
            sourcePanelID: sourcePanelID,
            rootDirectory: rootDirectory
        )
    }

    private func syncSessionIndexRoot(from workspace: Workspace, store: SessionIndexStore) {
        guard !workspace.usesRemoteDirectoryProvenance else {
            store.setCurrentDirectoryIfChanged(nil)
            return
        }

        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setCurrentDirectoryIfChanged(directory.isEmpty ? nil : directory)
    }

    private func syncGitGraphRoot(from workspace: Workspace, model: GitGraphPanelModel) {
        model.setDirectory(
            resolvedFileExplorerDirectory(from: workspace),
            isRemote: workspace.usesRemoteDirectoryProvenance
        )
    }
}

struct RightSidebarToolPanelView: View {
    @ObservedObject var panel: RightSidebarToolPanel
    @EnvironmentObject private var tabManager: TabManager
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let resolvedChromeBackgroundColor: NSColor
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: resolvedChromeBackgroundColor))
            .overlay {
                WorkspaceAttentionFlashRingView(opacity: focusFlashOpacity)
            }
            .simultaneousGesture(TapGesture().onEnded { requestPanelFocusIfNeeded() })
            .onChange(of: panel.focusFlashToken) { _, _ in
                triggerFocusFlashAnimation()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch panel.mode {
        case .files:
            FileWorkspacePanelView(
                model: panel.fileWorkspaceModel,
                explorerStore: panel.fileExplorerStore,
                explorerState: panel.fileExplorerState,
                isFocused: isFocused,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority,
                appearance: appearance,
                onOpenFile: panel.openFilePreview,
                onRequestPanelFocus: requestPanelFocusIfNeeded,
                onExplorerContainerChange: panel.attachFileExplorerContainer
            )
        case .gitGraph:
            GitGraphPanelView(
                model: panel.gitGraphModel,
                onFocus: requestPanelFocusIfNeeded
            )
        case .herd:
            HerdPanelView(
                model: panel.herdModel,
                onFocus: requestPanelFocusIfNeeded,
                onFocusAnchorChange: panel.attachToolFocusAnchor
            )
        case .find:
            FileExplorerPanelView(
                store: panel.fileExplorerStore,
                state: panel.fileExplorerState,
                onOpenFilePreview: panel.openFilePreview,
                presentation: .find,
                placement: .pane,
                onFocus: requestPanelFocusIfNeeded,
                onContainerChange: panel.attachFileExplorerContainer
            )
        case .sessions:
            SessionIndexView(
                store: panel.sessionIndexStore,
                chromeBackgroundColor: resolvedChromeBackgroundColor,
                onResume: { entry in
                    SessionEntryResumeCoordinator.resume(entry, tabManager: tabManager)
                }
            )
            .background(
                RightSidebarToolFocusAnchor(onViewChange: panel.attachToolFocusAnchor)
                    .frame(width: 0, height: 0)
            )
        case .feed, .dock, .machines, .customSidebar:
            EmptyView()
        }
    }

    private func requestPanelFocusIfNeeded() {
        guard !panel.isFocusedInWorkspace else { return }
        onRequestPanelFocus()
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

struct RightSidebarToolFocusAnchor: NSViewRepresentable {
    final class Coordinator {
        var onViewChange: (RightSidebarToolFocusAnchorView?) -> Void
        weak var attachedView: RightSidebarToolFocusAnchorView?

        init(onViewChange: @escaping (RightSidebarToolFocusAnchorView?) -> Void) {
            self.onViewChange = onViewChange
        }

        func attach(_ view: RightSidebarToolFocusAnchorView) {
            guard attachedView !== view else { return }
            attachedView = view
            onViewChange(view)
        }

        func detach(_ view: RightSidebarToolFocusAnchorView) {
            guard attachedView === view else { return }
            attachedView = nil
            onViewChange(nil)
        }
    }

    let onViewChange: (RightSidebarToolFocusAnchorView?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onViewChange: onViewChange)
    }

    func makeNSView(context: Context) -> RightSidebarToolFocusAnchorView {
        let view = RightSidebarToolFocusAnchorView()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: RightSidebarToolFocusAnchorView, context: Context) {
        context.coordinator.onViewChange = onViewChange
        context.coordinator.attach(nsView)
    }

    static func dismantleNSView(_ nsView: RightSidebarToolFocusAnchorView, coordinator: Coordinator) {
        coordinator.detach(nsView)
    }
}

final class RightSidebarToolFocusAnchorView: NSView {
    override var acceptsFirstResponder: Bool { true }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        guard let responderView = Self.view(for: responder) else { return false }
        guard let root = focusRootView else { return false }
        return responderView === root || responderView.isDescendant(of: root)
    }

    private static func view(for responder: NSResponder) -> NSView? {
        if let view = responder as? NSView {
            return view
        }
        if let textView = responder as? NSTextView,
           let delegateView = textView.delegate as? NSView {
            return delegateView
        }
        return nil
    }

    private var focusRootView: NSView? {
        guard let superview else { return nil }
        var current: NSView? = superview
        while let view = current {
            let typeName = String(describing: type(of: view))
            if typeName.contains("NSHosting") || typeName.contains("ViewHost") {
                return view
            }
            current = view.superview
        }
        return superview
    }
}
