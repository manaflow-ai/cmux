import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import Foundation
import SwiftUI

/// Renders the Dock's Bonsplit tree, reusing `PanelContentView` so Dock
/// terminals and browsers render identically to main-area panes.
struct DockSplitContentView: View {
    let store: DockSplitStore
    let appearance: PanelAppearance
    let appearanceRevision: UInt
    let windowAppearance: WindowAppearanceSnapshot
    let rightSidebarOwnsInputFocus: Bool
    let unreadPanelIDs: Set<UUID>

    var body: some View {
        BonsplitView(controller: store.bonsplitController) { tab, paneId in
            dockContent(tab: tab, paneId: paneId)
        } emptyPane: { paneId in
            DockEmptyPaneView(
                onNewTerminal: { _ = store.newSurface(kind: .terminal, inPane: paneId, focus: true) },
                onNewBrowser: { _ = store.newSurface(kind: .browser, inPane: paneId, focus: true) }
            )
            .onTapGesture { store.bonsplitController.focusPane(paneId) }
        }
        .background {
            DockPointerInteractionHost(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }

    func panelView(panel: any Panel, tabID: TabID, paneID: PaneID) -> DockSplitPanelContentView {
        DockSplitPanelContentView(
            store: store,
            panel: panel,
            tabID: tabID,
            paneID: paneID,
            appearance: appearance,
            appearanceRevision: appearanceRevision,
            windowAppearance: windowAppearance,
            rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus,
            hasUnreadNotification: unreadPanelIDs.contains(panel.id) ||
                store.manualUnreadPanelIds.contains(panel.id)
        )
    }

    @ViewBuilder
    private func dockContent(tab: Bonsplit.Tab, paneId: PaneID) -> some View {
        if let panel = store.panel(for: tab.id) {
            panelView(panel: panel, tabID: tab.id, paneID: paneId)
                .equatable()
                .onTapGesture { store.bonsplitController.focusPane(paneId) }
        } else {
            DockEmptyPaneView(
                onNewTerminal: { _ = store.newSurface(kind: .terminal, inPane: paneId, focus: true) },
                onNewBrowser: { _ = store.newSurface(kind: .browser, inPane: paneId, focus: true) }
            )
            .onTapGesture { store.bonsplitController.focusPane(paneId) }
        }
    }
}

/// Records Dock ownership at the pointer boundary before Bonsplit selection
/// callbacks run. This keeps user-originated focus independent from callbacks
/// that Bonsplit also emits for programmatic mutations.
@MainActor
private struct DockPointerInteractionHost: NSViewRepresentable {
    let store: DockSplitStore

    func makeNSView(context: Context) -> DockPointerInteractionHostView {
        let view = DockPointerInteractionHostView()
        view.store = store
        return view
    }

    func updateNSView(
        _ nsView: DockPointerInteractionHostView,
        context: Context
    ) {
        nsView.store = store
        nsView.installMonitorIfNeeded()
    }

    static func dismantleNSView(
        _ nsView: DockPointerInteractionHostView,
        coordinator: ()
    ) {
        nsView.stopMonitoring()
        nsView.store = nil
    }
}

@MainActor
private final class DockPointerInteractionHostView: NSView {
    var store: DockSplitStore?
    private var eventMonitor: Any?

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A SwiftUI host can migrate between windows while retaining this
        // representable. Rebind the monitor to the new window rather than
        // leaving an event monitor attached to the old one.
        stopMonitoring()
        installMonitorIfNeeded()
    }

    func installMonitorIfNeeded() {
        guard window != nil, eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] event in
            self?.handle(event: event)
            return event
        }
    }

    func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handle(event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        guard let hitView = window.contentView?.hitTest(event.locationInWindow),
              isDockHitView(hitView, at: event.locationInWindow, in: window) else {
            return
        }
        store?.noteUserDockPointerInteraction(window: window)
    }

    private func isDockHitView(
        _ view: NSView,
        at windowPoint: NSPoint,
        in window: NSWindow
    ) -> Bool {
        // Bonsplit owns the actual tab-bar AppKit hit regions. This remains
        // correct even when SwiftUI mounts the Dock tab strip in a separate
        // hosting subtree from this monitor view.
        if BonsplitTabBarHitRegionRegistry.containsWindowPoint(
            windowPoint,
            in: window
        ) {
            return true
        }

        guard let store else { return false }
        // Surface portals are intentionally reparented to a window-level host.
        // Resolve their stable panel identity directly from the portal hit
        // registry instead of scanning every Dock panel on each mouse-down.
        if let terminalView = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(
            windowPoint,
            in: window
        ),
           let panelId = terminalView.terminalSurface?.id,
           store.panelIsSelectedInVisibleDockPane(panelId) {
            return true
        }
        if let webView = BrowserWindowPortalRegistry.webViewAtWindowPoint(
            windowPoint,
            in: window
        ),
           let context = BrowserWindowPortalRegistry.paneDropContext(for: webView),
           context.isDockHosted,
           context.workspaceId == store.workspaceId,
           store.panelIsSelectedInVisibleDockPane(context.panelId) {
            return true
        }

        // File previews and other Dock-native panels do not have a window-level
        // portal identity. Resolve only the selected panel in each rendered
        // pane; this keeps the fallback proportional to the pane topology
        // rather than scanning every retained panel on every mouse-down.
        let renderedPaneIDs = store.bonsplitController.zoomedPaneId.map { [$0] }
            ?? store.bonsplitController.allPaneIds
        for paneID in renderedPaneIDs {
            guard store.paneIsRenderedInVisibleDock(paneID),
                  let tabID = store.bonsplitController.selectedTab(inPane: paneID)?.id,
                  let panelID = store.surfaceIdToPanelId[tabID],
                  let panel = store.panels[panelID] else {
                continue
            }
            if panel.ownedFocusIntent(for: view, in: window) != nil {
                return true
            }
        }
        return false
    }
}
