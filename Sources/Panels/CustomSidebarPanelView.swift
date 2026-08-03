import AppKit
import Combine
import CmuxAppKitSupportUI
import CmuxNotifications
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebar
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSwiftRender
import CmuxSwiftRenderUI

@MainActor
final class CustomSidebarPanelViewController: NSViewController,
    PanelContentControllerUpdating,
    NSGestureRecognizerDelegate
{
    private let contentContainer = NSView()
    private let flashRing = WorkspaceAttentionFlashRingNativeView(frame: .zero)
    private let focusAnchor = RightSidebarToolFocusAnchorView(frame: .zero)
    private let renderWorkerClientStore = RenderWorkerClientStore()
    private var backdropLayer: WindowBackdropLayer?
    private var surface: CustomSidebarSurface?
    private weak var panel: CustomSidebarPanel?
    private var configuration: PanelContentConfiguration
    private var rendererMode: CustomSidebarRendererMode = .inProcess
    private var rendererTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var flashCancellable: AnyCancellable?
    private var observedJSONStore: JSONConfigStore?

    init(configuration: PanelContentConfiguration) {
        self.configuration = configuration
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
        root.layer?.masksToBounds = true
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
        guard let panel = configuration.panel as? CustomSidebarPanel,
              let tabManager = configuration.customSidebarTabManager,
              let windowAppearance = configuration.windowAppearance else { return }
        self.configuration = configuration
        loadViewIfNeeded()
        view.layer?.backgroundColor = configuration.appearance.backgroundColor.cgColor
        view.layer?.cornerRadius = windowAppearance.sidebarSettings.materialPolicy.cornerRadius
        view.appearance = NSAppearance(
            named: windowAppearance.sidebarContentColorScheme == .dark ? .darkAqua : .aqua
        )
        updateBackdrop(windowAppearance)
        observePanel(panel)
        observeRenderer(configuration.settingsRuntime)
        panel.attachFocusAnchor(focusAnchor)

        if configuration.isVisibleInUI {
            refreshSurface(now: Date(), panel: panel, tabManager: tabManager)
            startRefreshLoop()
        } else {
            stopRendering()
        }
    }

    func teardownPanelContent() {
        rendererTask?.cancel()
        rendererTask = nil
        observedJSONStore = nil
        refreshTask?.cancel()
        refreshTask = nil
        flashCancellable = nil
        surface?.teardown()
        surface?.removeFromSuperview()
        surface = nil
        renderWorkerClientStore.shutdown()
        panel?.attachFocusAnchor(nil)
        panel = nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        true
    }

    private func updateBackdrop(_ snapshot: WindowAppearanceSnapshot) {
        if let backdropLayer {
            backdropLayer.update(role: .rightSidebar, snapshot: snapshot)
            return
        }
        let backdrop = WindowBackdropLayer(role: .rightSidebar, snapshot: snapshot)
        contentContainer.addSubview(backdrop, positioned: .below, relativeTo: surface)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        backdropLayer = backdrop
    }

    private func observePanel(_ panel: CustomSidebarPanel) {
        guard self.panel !== panel else { return }
        flashCancellable = panel.$focusFlashToken
            .dropFirst()
            .sink { [weak flashRing] _ in
                Task { @MainActor in
                    flashRing?.triggerFlash(reason: .navigation)
                }
            }
        self.panel?.attachFocusAnchor(nil)
        self.panel = panel
    }

    private func observeRenderer(_ runtime: SettingsRuntime?) {
        guard observedJSONStore !== runtime?.jsonStore else { return }
        rendererTask?.cancel()
        rendererTask = nil
        observedJSONStore = runtime?.jsonStore
        guard let runtime else {
            rendererMode = SettingCatalog().customSidebars.renderer.defaultValue
            return
        }
        let key = runtime.catalog.customSidebars.renderer
        rendererTask = Task { @MainActor [weak self] in
            for await mode in runtime.jsonStore.values(for: key) {
                guard !Task.isCancelled, let self else { return }
                guard self.rendererMode != mode else { continue }
                self.rendererMode = mode
                if mode == .inProcess {
                    self.renderWorkerClientStore.shutdown()
                }
                self.refreshCurrentSurface()
            }
        }
    }

    private func startRefreshLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                self?.refreshCurrentSurface()
                do {
                    try await clock.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func refreshCurrentSurface() {
        guard configuration.isVisibleInUI,
              let panel,
              let tabManager = configuration.customSidebarTabManager else { return }
        refreshSurface(now: Date(), panel: panel, tabManager: tabManager)
    }

    private func refreshSurface(now: Date, panel: CustomSidebarPanel, tabManager: TabManager) {
        let dataContext = customSidebarDataContext(
            now: now,
            tabManager: tabManager,
            sidebarUnread: configuration.customSidebarUnread
        )
        let rendersInProcess = rendererMode == .inProcess
        if let surface {
            surface.update(
                fileURL: panel.fileURL,
                dataContext: dataContext,
                dispatch: makeCmuxSidebarActionDispatch(),
                contentInsets: .zero,
                rendersInProcess: rendersInProcess
            )
            return
        }
        let surface = CustomSidebarSurface(
            fileURL: panel.fileURL,
            dataContext: dataContext,
            dispatch: makeCmuxSidebarActionDispatch(),
            contentInsets: .zero,
            rendersInProcess: rendersInProcess,
            clientStore: renderWorkerClientStore
        )
        self.surface = surface
        contentContainer.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            surface.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            surface.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func stopRendering() {
        refreshTask?.cancel()
        refreshTask = nil
        surface?.teardown()
        surface?.removeFromSuperview()
        surface = nil
        renderWorkerClientStore.shutdown()
    }

    private func customSidebarDataContext(
        now: Date,
        tabManager: TabManager,
        sidebarUnread: SidebarUnreadModel
    ) -> [String: SwiftValue] {
        CustomSidebarPaneDataContextCache.shared.dataContext(
            now: now,
            tabManager: tabManager,
            sidebarUnread: sidebarUnread
        ) {
            let selectedID = tabManager.selectedTabId
            let workspaces = tabManager.tabs.enumerated().map { index, workspace in
                workspace.customSidebarWorkspaceSnapshot(
                    index: index,
                    selectedId: selectedID,
                    unreadCount: sidebarUnread.unreadCount(forWorkspaceId: workspace.id)
                )
            }
            let selectedWorkspace = tabManager.tabs.first { $0.id == selectedID }
            let snapshot = CustomSidebarContextSnapshot(
                workspaces: workspaces,
                selectedWorkspaceId: selectedID,
                selectedWorkspaceTitle: selectedWorkspace?.customTitle ?? selectedWorkspace?.title ?? "",
                totalUnreadCount: sidebarUnread.totalUnreadCount,
                now: now
            )
            return CustomSidebarDataContextBuilder().dataContext(for: snapshot)
        }
    }

    private func requestPanelFocusIfNeeded() {
        guard panel?.isFocusedInWorkspace == false else { return }
        configuration.onRequestPanelFocus()
    }

    @objc private func requestPanelFocus(_ recognizer: NSClickGestureRecognizer) {
        requestPanelFocusIfNeeded()
    }

    isolated deinit {
        rendererTask?.cancel()
        refreshTask?.cancel()
    }
}
