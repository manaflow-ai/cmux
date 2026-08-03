import AppKit
import Bonsplit

/// Native Bonsplit content controller for one Dock tab. It preserves the
/// ``PanelContentViewController`` across appearance and unread refreshes.
@MainActor
final class DockSplitPanelContentHostingController: NSViewController,
    BonsplitContentUpdating,
    BonsplitPaneDropZoneReceiving
{
    private let context: DockSplitPresentationContext
    private let containerView = NSView()
    private var tab: Bonsplit.Tab
    private var paneID: PaneID
    private var dropZone: DropZone?
    private var panelController: PanelContentViewController?

    init(context: DockSplitPresentationContext, tab: Bonsplit.Tab, paneID: PaneID) {
        self.context = context
        self.tab = tab
        self.paneID = paneID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        containerView.wantsLayer = true
        let click = NSClickGestureRecognizer(target: self, action: #selector(focusPane(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        containerView.addGestureRecognizer(click)
        view = containerView
        render()
    }

    func updateBonsplitContent(tab: Bonsplit.Tab, pane: PaneID) {
        self.tab = tab
        self.paneID = pane
        render()
    }

    func bonsplitPaneDropZoneDidChange(_ zone: DropZone?) {
        dropZone = zone
        render()
    }

    private func render() {
        guard isViewLoaded,
              let panel = context.store.panel(for: tab.id)
        else {
            removePanelController()
            containerView.layer?.backgroundColor = context.appearance.backgroundColor.cgColor
            return
        }
        containerView.layer?.backgroundColor = context.appearance.backgroundColor.cgColor
        let configuration = makeConfiguration(panel: panel)
        if let panelController {
            panelController.update(configuration: configuration)
            return
        }
        let controller = PanelContentViewController(configuration: configuration)
        panelController = controller
        addChild(controller)
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            child.topAnchor.constraint(equalTo: containerView.topAnchor),
            child.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
    }

    private func makeConfiguration(panel: any Panel) -> PanelContentConfiguration {
        let store = context.store
        let isFocused = store.panelIsActiveInVisibleDockPane(panel.id)
            && context.rightSidebarOwnsInputFocus
        let isSelectedInPane = store.bonsplitController.selectedTab(inPane: paneID)?.id == tab.id
        let isVisibleInUI = store.panelIsSelectedInVisibleDockPane(panel.id)
        let currentPaneID = paneID
        return PanelContentConfiguration(
            panel: panel,
            workspaceID: store.workspaceId,
            paneID: paneID,
            isFocused: isFocused,
            isSelectedInPane: isSelectedInPane,
            isVisibleInUI: isVisibleInUI,
            allowsPointerInput: isVisibleInUI,
            pointerEntryEventFilter: nil,
            portalPriority: 1,
            isSplit: store.bonsplitController.allPaneIds.count > 1,
            appearance: context.appearance,
            windowAppearance: context.windowAppearance,
            customSidebarTabManager: nil,
            customSidebarUnread: TerminalNotificationStore.shared.sidebarUnread,
            hasUnreadNotification: context.unreadPanelIDs.contains(panel.id),
            terminalAgentContext: "",
            paneOwnershipOverride: isVisibleInUI,
            terminalPaneOwnershipResolver: {
                guard store.paneId(forPanelId: panel.id)?.id == currentPaneID.id else { return false }
                return store.panelIsSelectedInVisibleDockPane(panel.id)
            },
            paneDropZone: dropZone,
            onFocus: {
                store.focusPanelFromDockInteraction(
                    panel.id,
                    window: NSApp.keyWindow ?? NSApp.mainWindow
                )
            },
            onRequestPanelFocus: {
                store.focusPanelFromDockInteraction(
                    panel.id,
                    window: NSApp.keyWindow ?? NSApp.mainWindow
                )
            },
            onResumeAgentHibernation: {
                _ = store.resumeAgentHibernation(panelId: panel.id, focus: true)
            },
            onAutoResumeAgentHibernation: {
                _ = store.resumeAgentHibernation(panelId: panel.id, focus: false)
            },
            onTriggerFlash: {}
        )
    }

    private func removePanelController() {
        guard let panelController else { return }
        panelController.teardown()
        panelController.view.removeFromSuperview()
        panelController.removeFromParent()
        self.panelController = nil
    }

    @objc private func focusPane(_ sender: NSClickGestureRecognizer) {
        context.store.bonsplitController.focusPane(paneID)
    }
}
