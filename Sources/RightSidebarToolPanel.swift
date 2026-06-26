import AppKit
import CmuxFoundation
import Combine
import SwiftUI

@MainActor
final class RightSidebarToolPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .rightSidebarTool
    let mode: RightSidebarMode

    @Published private(set) var focusFlashToken: Int = 0

    private weak var workspace: Workspace?
    private weak var fileExplorerContainerView: FileExplorerContainerView?
    private weak var sessionIndexFocusAnchorView: RightSidebarToolFocusAnchorView?
    private var fileExplorerStoreStorage: FileExplorerStore?
    private var fileExplorerStateStorage: FileExplorerState?
    private var sessionIndexStoreStorage: SessionIndexStore?
    private var workspaceObservationCancellable: AnyCancellable?

    init(workspace: Workspace, mode: RightSidebarMode) {
        self.id = UUID()
        self.mode = mode
        reattach(to: workspace)
    }

    deinit {
        // Explicit no-op so future teardown has a single home.
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

    var sessionIndexStore: SessionIndexStore {
        if let store = sessionIndexStoreStorage { return store }
        let store = SessionIndexStore()
        sessionIndexStoreStorage = store
        if let workspace {
            syncSessionIndexRoot(from: workspace, store: store)
        }
        return store
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

    fileprivate func attachSessionIndexFocusAnchor(_ anchor: RightSidebarToolFocusAnchorView?) {
        sessionIndexFocusAnchorView = anchor
    }

    func syncWorkspaceRoot(from workspace: Workspace) {
        switch mode {
        case .files, .find:
            guard let store = fileExplorerStoreStorage else { return }
            syncFileExplorerRoot(from: workspace, store: store)
        case .sessions:
            guard let store = sessionIndexStoreStorage else { return }
            syncSessionIndexRoot(from: workspace, store: store)
        case .feed, .dock:
            break
        }
    }

    func openFilePreview(_ filePath: String) {
        guard let workspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
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

    var isFocusedInWorkspace: Bool {
        workspace?.focusedPanelId == id
    }

    func close() {
        fileExplorerContainerView = nil
        sessionIndexFocusAnchorView = nil
        fileExplorerStoreStorage?.applyWorkspaceRoot(.none)
        sessionIndexStoreStorage?.setCurrentDirectoryIfChanged(nil)
        workspaceObservationCancellable = nil
    }

    func focus() {
        switch mode {
        case .files:
            _ = fileExplorerContainerView?.focusOutline()
        case .find:
            _ = fileExplorerContainerView?.focusSearchField()
        case .sessions:
            guard let anchor = sessionIndexFocusAnchorView,
                  let window = anchor.window else { return }
            _ = window.makeFirstResponder(anchor)
        case .feed, .dock:
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
            guard fileExplorerContainerView?.ownsKeyboardFocus(responder) == true else { return nil }
            return .panel
        case .sessions:
            guard sessionIndexFocusAnchorView?.ownsKeyboardFocus(responder) == true else { return nil }
            return .panel
        case .feed, .dock:
            return nil
        }
    }

    private func observeWorkspaceRootChanges(_ workspace: Workspace) {
        workspaceObservationCancellable = Publishers.MergeMany(
            workspace.currentDirectoryPublisher.map { _ in () }.eraseToAnyPublisher(),
            workspace.remoteConfigurationPublisher.map { _ in () }.eraseToAnyPublisher(),
            workspace.remoteConnectionStatePublisher.map { _ in () }.eraseToAnyPublisher(),
            workspace.remoteConnectionDetailPublisher.map { _ in () }.eraseToAnyPublisher(),
            workspace.remoteDaemonStatusPublisher.map { _ in () }.eraseToAnyPublisher()
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

        if workspace.isRemoteWorkspace {
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
                    rootPath: workspace.currentDirectory,
                    isAvailable: workspace.remoteConnectionState == .connected,
                    unavailableDetail: unavailableDetail
                )
            )
            return
        }

        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else {
            store.applyWorkspaceRoot(.none)
            return
        }

        store.applyWorkspaceRoot(.local(workspaceId: workspace.id, path: directory))
    }

    private func syncSessionIndexRoot(from workspace: Workspace, store: SessionIndexStore) {
        guard !workspace.isRemoteWorkspace else {
            store.setCurrentDirectoryIfChanged(nil)
            return
        }

        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setCurrentDirectoryIfChanged(directory.isEmpty ? nil : directory)
    }
}

struct RightSidebarToolPanelView: View {
    @ObservedObject var panel: RightSidebarToolPanel
    @Environment(TabManager.self) private var tabManager
    let isFocused: Bool
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: appearance.backgroundColor))
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
            FileExplorerPanelView(
                store: panel.fileExplorerStore,
                state: panel.fileExplorerState,
                onOpenFilePreview: panel.openFilePreview,
                presentation: .files,
                placement: .pane,
                onFocus: requestPanelFocusIfNeeded,
                onContainerChange: panel.attachFileExplorerContainer
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
                onResume: { entry in
                    tabManager.resume(entry)
                }
            )
            .background(
                RightSidebarToolFocusAnchor(onViewChange: panel.attachSessionIndexFocusAnchor)
                    .frame(width: 0, height: 0)
            )
        case .feed, .dock:
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

private struct RightSidebarToolFocusAnchor: NSViewRepresentable {
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

fileprivate final class RightSidebarToolFocusAnchorView: NSView {
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
