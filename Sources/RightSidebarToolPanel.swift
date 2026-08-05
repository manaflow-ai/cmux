import AppKit
import Combine

@MainActor
final class RightSidebarToolPanel: Panel, ObservableObject {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
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
        case .feed, .dock, .customSidebar:
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
        case .feed, .dock, .customSidebar:
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
        case .feed, .dock, .customSidebar:
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
                    rootPath: workspace.trustedRemoteCurrentDirectory,
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
        guard !workspace.usesRemoteDirectoryProvenance else {
            store.setCurrentDirectoryIfChanged(nil)
            return
        }

        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setCurrentDirectoryIfChanged(directory.isEmpty ? nil : directory)
    }
}

@MainActor
final class RightSidebarToolPanelViewController: NSViewController,
    PanelContentControllerUpdating,
    NSGestureRecognizerDelegate
{
    private let contentContainer = NSView()
    private let flashRing = WorkspaceAttentionFlashRingNativeView(frame: .zero)
    private let focusAnchor = RightSidebarToolFocusAnchorView(frame: .zero)
    private var fileExplorerController: FileExplorerPanelController?
    private var sessionController: SessionIndexNativeViewController?
    private weak var panel: RightSidebarToolPanel?
    private var flashCancellable: AnyCancellable?
    private var onRequestPanelFocus: () -> Void = {}

    init(configuration: PanelContentConfiguration) {
        super.init(nibName: nil, bundle: nil)
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        flashRing.translatesAutoresizingMaskIntoConstraints = false
        focusAnchor.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentContainer)
        root.addSubview(flashRing)
        root.addSubview(focusAnchor)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            flashRing.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            flashRing.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            flashRing.topAnchor.constraint(equalTo: root.topAnchor),
            flashRing.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            focusAnchor.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            focusAnchor.topAnchor.constraint(equalTo: root.topAnchor),
            focusAnchor.widthAnchor.constraint(equalToConstant: 0),
            focusAnchor.heightAnchor.constraint(equalToConstant: 0),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(requestPanelFocus(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        click.delegate = self
        root.addGestureRecognizer(click)
        view = root
    }

    func update(configuration: PanelContentConfiguration) {
        guard let panel = configuration.panel as? RightSidebarToolPanel else { return }
        loadViewIfNeeded()
        onRequestPanelFocus = configuration.onRequestPanelFocus
        view.layer?.backgroundColor = configuration.appearance.backgroundColor.cgColor
        observeFlash(on: panel)

        switch panel.mode {
        case .files, .find:
            installFileExplorer(panel: panel, presentation: panel.mode == .files ? .files : .find)
        case .sessions:
            guard let tabManager = configuration.customSidebarTabManager else { return }
            installSessionIndex(panel: panel, tabManager: tabManager)
        case .feed, .dock, .customSidebar:
            clearInstalledContent()
        }
    }

    func teardownPanelContent() {
        flashCancellable = nil
        fileExplorerController?.teardown()
        fileExplorerController = nil
        sessionController?.teardown()
        sessionController?.view.removeFromSuperview()
        sessionController?.removeFromParent()
        sessionController = nil
        panel?.attachFileExplorerContainer(nil)
        panel?.attachSessionIndexFocusAnchor(nil)
        panel = nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        true
    }

    private func installFileExplorer(
        panel: RightSidebarToolPanel,
        presentation: FileExplorerPanelPresentation
    ) {
        if sessionController != nil || fileExplorerController == nil {
            clearInstalledContent()
            let controller = FileExplorerPanelController(
                store: panel.fileExplorerStore,
                state: panel.fileExplorerState,
                onOpenFilePreview: panel.openFilePreview,
                presentation: presentation,
                placement: .pane,
                onFocus: { [weak self] in self?.requestPanelFocusIfNeeded() },
                onContainerChange: panel.attachFileExplorerContainer
            )
            fileExplorerController = controller
            install(view: controller.containerView)
        }
        fileExplorerController?.update(
            store: panel.fileExplorerStore,
            state: panel.fileExplorerState,
            onOpenFilePreview: panel.openFilePreview,
            presentation: presentation,
            placement: .pane,
            onFocus: { [weak self] in self?.requestPanelFocusIfNeeded() },
            onContainerChange: panel.attachFileExplorerContainer
        )
    }

    private func installSessionIndex(panel: RightSidebarToolPanel, tabManager: TabManager) {
        if fileExplorerController != nil || sessionController == nil {
            clearInstalledContent()
            let controller = SessionIndexNativeViewController(
                store: panel.sessionIndexStore,
                onResume: { [weak tabManager] entry in
                    guard let tabManager else { return }
                    SessionEntryResumeCoordinator.resume(entry, tabManager: tabManager)
                }
            )
            addChild(controller)
            sessionController = controller
            install(view: controller.view)
            panel.attachSessionIndexFocusAnchor(focusAnchor)
        } else {
            sessionController?.update(
                store: panel.sessionIndexStore,
                onResume: { [weak tabManager] entry in
                    guard let tabManager else { return }
                    SessionEntryResumeCoordinator.resume(entry, tabManager: tabManager)
                }
            )
        }
    }

    private func install(view contentView: NSView) {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func clearInstalledContent() {
        fileExplorerController?.teardown()
        fileExplorerController = nil
        sessionController?.teardown()
        sessionController?.view.removeFromSuperview()
        sessionController?.removeFromParent()
        sessionController = nil
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        panel?.attachFileExplorerContainer(nil)
        panel?.attachSessionIndexFocusAnchor(nil)
    }

    private func observeFlash(on panel: RightSidebarToolPanel) {
        guard self.panel !== panel else { return }
        flashCancellable = panel.$focusFlashToken
            .dropFirst()
            .sink { [weak flashRing] _ in
                Task { @MainActor in
                    flashRing?.triggerFlash(reason: .navigation)
                }
            }
        self.panel = panel
    }

    private func requestPanelFocusIfNeeded() {
        guard panel?.isFocusedInWorkspace == false else { return }
        onRequestPanelFocus()
    }

    @objc private func requestPanelFocus(_ recognizer: NSClickGestureRecognizer) {
        requestPanelFocusIfNeeded()
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
        superview
    }
}
