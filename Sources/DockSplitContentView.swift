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
        .accessibilityIdentifier("DockSplitContent")
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
              isDockHitView(hitView, in: window) else {
            return
        }
        store?.noteUserDockPointerInteraction(window: window)
    }

    private func isDockHitView(_ view: NSView, in window: NSWindow) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current.accessibilityIdentifier == "DockSplitContent"
                || current.accessibilityIdentifier == "DockPanel" {
                return true
            }
            candidate = current.superview
        }

        // Terminal and browser portals are reparented into a window-level host
        // during split churn, so their hit view may sit outside the SwiftUI
        // accessibility container. Resolve those through the Dock's ownership
        // registry instead of treating the whole window as Dock content.
        if let store,
           let terminalView = view.cmuxStrictOwningGhosttyView(),
           let surfaceId = terminalView.terminalSurface?.id,
           store.containsPanel(surfaceId) {
            return true
        }
        if store?.browserPanel(owning: view, in: window) != nil {
            return true
        }
        return false
    }
}
