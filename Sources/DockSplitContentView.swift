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
struct DockPointerInteractionHost: NSViewRepresentable {
    let store: DockSplitStore
    let isEnabled: Bool

    func makeNSView(context: Context) -> DockPointerInteractionHostView {
        let view = DockPointerInteractionHostView()
        view.store = store
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(
        _ nsView: DockPointerInteractionHostView,
        context: Context
    ) {
        nsView.store = store
        nsView.isEnabled = isEnabled
        if isEnabled {
            nsView.installMonitorIfNeeded()
        } else {
            nsView.stopMonitoring()
        }
    }

    static func dismantleNSView(
        _ nsView: DockPointerInteractionHostView,
        coordinator: ()
    ) {
        nsView.stopMonitoring()
        nsView.store = nil
    }
}

/// Owns one local event monitor and removes it deterministically at teardown.
/// The opaque token is never inspected outside the MainActor except for the
/// final deinit handoff, where it is immutable and consumed exactly once.
private final class DockPointerMonitorToken: @unchecked Sendable {
    let raw: Any

    init(raw: Any) {
        self.raw = raw
    }
}

@MainActor
private final class DockPointerMonitorLease {
    private var token: DockPointerMonitorToken?

    @MainActor
    func install(
        handler: @escaping (NSEvent) -> NSEvent?
    ) {
        guard token == nil else { return }
        guard let raw = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown],
            handler: handler
        ) else {
            return
        }
        token = DockPointerMonitorToken(raw: raw)
    }

    @MainActor
    func stop() {
        guard let token else { return }
        NSEvent.removeMonitor(token.raw)
        self.token = nil
    }

    deinit {
        guard let token else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                NSEvent.removeMonitor(token.raw)
            }
        } else {
            // Deinitialization can follow an off-main autorelease drain. Keep
            // AppKit mutation on the MainActor in that uncommon fallback.
            Task { @MainActor [token] in
                NSEvent.removeMonitor(token.raw)
            }
        }
    }

}

@MainActor
final class DockPointerInteractionHostView: NSView {
    var store: DockSplitStore?
    var isEnabled = false
    private let monitorLease = DockPointerMonitorLease()

    deinit {
        // ``DockPointerMonitorLease`` owns the token and performs the final
        // MainActor cleanup even if SwiftUI skips ``dismantleNSView``.
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
        guard isEnabled, window != nil else { return }
        monitorLease.install { [weak self] event in
            self?.handle(event: event)
            return event
        }
    }

    func stopMonitoring() {
        monitorLease.stop()
    }

    private func handle(event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        // This host is mounted at the DockPanel root, so its own bounds are the
        // explicit Dock ownership region (including the Bonsplit tab strip).
        // Keep clicks outside that region off the full-window hit-test path.
        guard bounds.contains(point),
              let hitView = window.contentView?.hitTest(event.locationInWindow),
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
        if BonsplitTabItemHitRegionRegistry.containsWindowPoint(
            windowPoint,
            in: window
        ) {
            // The tab-item region also contains accessory buttons (close,
            // mute, pin, and zoom). Those controls deliberately keep the
            // current first responder, so they must not claim Dock focus.
            return !isInteractiveDockChrome(view)
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

    private func isInteractiveDockChrome(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if let button = current as? NSButton, button.isEnabled {
                return true
            }
            if let textField = current as? NSTextField, textField.isEditable {
                return true
            }
            if let textView = current as? NSTextView, textView.isEditable {
                return true
            }
            if let control = current as? NSControl,
               control.isEnabled,
               control.target != nil,
               control.action != nil {
                return true
            }
            candidate = current.superview
        }
        return false
    }
}
