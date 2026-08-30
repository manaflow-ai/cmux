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
        if nsView.store !== store {
            nsView.store?.cancelDockPointerInteraction()
        }
        nsView.store = store
        nsView.isEnabled = isEnabled
        nsView.refreshTeardownCleanup()
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

/// Owns the MainActor cleanup closure for an AppKit monitor. The immutable box
/// reference can be requested from a nonisolated deinit; the captured handles
/// are read and consumed only on the MainActor.
private final class DockPointerTeardownBox: @unchecked Sendable {
    @MainActor
    private var cleanup: (@MainActor () -> Void)?

    @MainActor
    func replace(with cleanup: (@MainActor () -> Void)?) {
        self.cleanup = cleanup
    }

    @MainActor
    func perform() {
        let cleanup = self.cleanup
        self.cleanup = nil
        cleanup?()
    }

    nonisolated func request() {
        Task { @MainActor [self] in
            self.perform()
        }
    }
}

@MainActor
final class DockPointerInteractionHostView: NSView {
    var store: DockSplitStore?
    var isEnabled = false
    private weak var registeredWindow: NSWindow?
    private var windowResignKeyObserver: NSObjectProtocol?
    private var applicationResignActiveObserver: NSObjectProtocol?
    // The reference is immutable and its methods marshal all handle access to
    // the MainActor, which makes it safe to request from `deinit`.
    nonisolated(unsafe) private var teardownBox = DockPointerTeardownBox()

    deinit {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                teardownBox.perform()
            }
        } else {
            // SwiftUI normally calls `dismantleNSView` on the MainActor. If a
            // host is released elsewhere, request the same lifecycle cleanup
            // without reading actor-isolated handles from this deinit.
            teardownBox.request()
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
        guard isEnabled, let window else { return }
        if registeredWindow === window {
            refreshTeardownCleanup()
            return
        }
        stopMonitoring()
        registeredWindow = window
        DockPointerInteractionEventRouter.shared.register(self, in: window)
        windowResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            self?.store?.cancelDockPointerInteraction(window: window)
        }
        applicationResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self, weak window] _ in
            self?.store?.cancelDockPointerInteraction(window: window)
        }
        refreshTeardownCleanup()
    }

    /// Rebinds the deinit cleanup to the store currently used by this host.
    /// SwiftUI may reuse the AppKit view while replacing its store.
    func refreshTeardownCleanup() {
        guard let registeredWindow else {
            teardownBox.replace(with: nil)
            return
        }
        let hostID = ObjectIdentifier(self)
        let ownerStore = store
        let installedWindowObserver = windowResignKeyObserver
        let installedApplicationObserver = applicationResignActiveObserver
        teardownBox.replace(with: { [weak ownerStore] in
            ownerStore?.cancelDockPointerInteraction(window: registeredWindow)
            DockPointerInteractionEventRouter.shared.unregister(
                hostID: hostID,
                in: registeredWindow
            )
            if let installedWindowObserver {
                NotificationCenter.default.removeObserver(installedWindowObserver)
            }
            if let installedApplicationObserver {
                NotificationCenter.default.removeObserver(installedApplicationObserver)
            }
        })
    }

    func stopMonitoring() {
        // A host can move between windows while a pointer sequence is in
        // flight. Clear the coordinator unconditionally before rebinding.
        teardownBox.perform()
        registeredWindow = nil
        windowResignKeyObserver = nil
        applicationResignActiveObserver = nil
    }

    func handlePointerEvent(_ event: NSEvent) {
        guard let window else { return }
        guard event.window === window else { return }

        switch event.type {
        case .leftMouseDown:
            // A new pointer sequence supersedes any origin that was not
            // consumed by Bonsplit (for example, a click on an accessory).
            store?.cancelDockPointerInteraction()
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point),
                  !event.modifierFlags.contains(.control) else {
                return
            }
            // A SwiftUI remount can briefly leave no AppKit hit view at the
            // pointer location. The host's own bounds remain the authoritative
            // Dock region, so only reject a known non-Dock/control hit.
            let hitView = window.contentView?.hitTest(event.locationInWindow)
            guard let target = dockPointerHitTarget(
                hitView,
                at: event.locationInWindow,
                in: window
            ) else {
                return
            }
            switch target {
            case .tabItem:
                store?.beginUserDockPointerInteraction(window: window)
            case .panel:
                // Panel clicks already focus the selected panel through the
                // normal portal/AppKit path. Publish ownership without
                // creating a selection-origin lease that no callback will
                // consume.
                store?.noteKeyboardFocusIntent(window: window)
            }
        case .leftMouseUp:
            store?.releaseDockPointerInteraction(window: window)
        case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            store?.cancelDockPointerInteraction(window: window)
        default:
            break
        }
    }

    private func dockPointerHitTarget(
        _ view: NSView?,
        at windowPoint: NSPoint,
        in window: NSWindow
    ) -> DockPointerHitTarget? {
        let isInteractiveChrome = view.map(isInteractiveDockChrome) ?? false

        // Bonsplit owns the actual tab-item AppKit hit regions. Consult both
        // the registry and the provider in the hit-view ancestry: the latter
        // covers the short remount window before the registry is repopulated.
        let registryTabItemHit = BonsplitTabItemHitRegionRegistry.containsWindowPoint(
            windowPoint,
            in: window
        )
        let hierarchyTabItemHit = tabItemHitInViewHierarchy(view, at: windowPoint)

        guard let store else { return nil }
        // Surface portals are intentionally reparented to a window-level host.
        // Resolve their stable panel identity directly from the portal hit
        // registry when available; the root host remains the authoritative Dock
        // ownership region when a portal/tab registry is between remounts.
        let selectedPanelHit: Bool
        if let view,
           let terminalView = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(
            windowPoint,
            in: window
        ),
           isView(view, within: terminalView),
           let panelId = terminalView.terminalSurface?.id,
           store.panelIsSelectedInVisibleDockPane(panelId) {
            selectedPanelHit = true
        } else if let view,
                  let webView = BrowserWindowPortalRegistry.webViewAtWindowPoint(
                      windowPoint,
                      in: window
                  ),
                  isView(view, within: webView),
                  let context = BrowserWindowPortalRegistry.paneDropContext(for: webView),
                  context.isDockHosted,
                  context.workspaceId == store.workspaceId,
                  store.panelIsSelectedInVisibleDockPane(context.panelId) {
            selectedPanelHit = true
        } else {
            selectedPanelHit = selectedDockNativePanelHit(
                view: view,
                store: store,
                window: window
            )
        }

        return DockPointerHitClassification.target(
            registryTabItemHit: registryTabItemHit,
            hierarchyTabItemHit: hierarchyTabItemHit,
            interactiveChromeHit: isInteractiveChrome,
            selectedPanelHit: selectedPanelHit
        )
    }

    private func selectedDockNativePanelHit(
        view: NSView?,
        store: DockSplitStore,
        window: NSWindow
    ) -> Bool {

        // File previews and other Dock-native panels do not have a window-level
        // portal identity. Resolve only the selected panel in each rendered
        // pane; an unrelated overlay has no panel-owned focus intent and fails
        // closed here.
        guard let view else { return false }
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

    private func tabItemHitInViewHierarchy(
        _ view: NSView?,
        at windowPoint: NSPoint
    ) -> Bool {
        var candidate = view
        while let current = candidate {
            if let provider = current as? BonsplitTabItemHitRegionProviding {
                let localPoint = current.convert(windowPoint, from: nil)
                if provider.containsBonsplitTabItemHit(localPoint: localPoint) {
                    return true
                }
            }
            candidate = current.superview
        }
        return false
    }

    private func isView(_ view: NSView, within owner: NSView) -> Bool {
        view === owner || view.isDescendant(of: owner) || owner.isDescendant(of: view)
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
            candidate = current.superview
        }
        return false
    }
}
