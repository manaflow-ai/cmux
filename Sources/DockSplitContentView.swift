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

@MainActor
final class DockPointerInteractionHostView: NSView {
    var store: DockSplitStore?
    var isEnabled = false
    private var eventMonitor: Any?
    private var windowResignKeyObserver: NSObjectProtocol?
    private var applicationResignActiveObserver: NSObjectProtocol?

    deinit {
        // `deinit` is nonisolated under Swift 6. Remove AppKit monitors and
        // observers directly so a skipped SwiftUI dismantle cannot leak a
        // process-wide callback.
        let retainedStore = store
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                retainedStore?.cancelDockPointerInteraction()
            }
        } else if let retainedStore {
            // AppKit normally releases this view on the main thread. Keep the
            // uncommon off-main teardown safe without touching actor state
            // synchronously from the wrong executor.
            Task { @MainActor in
                retainedStore.cancelDockPointerInteraction()
            }
        }
        let eventMonitor = eventMonitor
        let windowResignKeyObserver = windowResignKeyObserver
        let applicationResignActiveObserver = applicationResignActiveObserver
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let windowResignKeyObserver {
            NotificationCenter.default.removeObserver(windowResignKeyObserver)
        }
        if let applicationResignActiveObserver {
            NotificationCenter.default.removeObserver(applicationResignActiveObserver)
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
        guard isEnabled, let window, eventMonitor == nil else { return }
        let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .leftMouseDown,
                .leftMouseDragged,
                .leftMouseUp,
                .keyDown,
            ]
        ) { [weak self] event in
            self?.handle(event: event)
            return event
        }
        guard let monitor else { return }
        eventMonitor = monitor
        windowResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.store?.cancelDockPointerInteraction(window: window)
        }
        applicationResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.store?.cancelDockPointerInteraction(window: window)
        }
    }

    func stopMonitoring() {
        // A host can move between windows while a pointer sequence is in
        // flight. Clear the coordinator unconditionally before rebinding.
        store?.cancelDockPointerInteraction()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let windowResignKeyObserver {
            NotificationCenter.default.removeObserver(windowResignKeyObserver)
            self.windowResignKeyObserver = nil
        }
        if let applicationResignActiveObserver {
            NotificationCenter.default.removeObserver(applicationResignActiveObserver)
            self.applicationResignActiveObserver = nil
        }
    }

    private func handle(event: NSEvent) {
        guard let window else { return }
        guard event.window === window else {
            if event.type == .leftMouseDown
                || event.type == .leftMouseDragged
                || event.type == .leftMouseUp
                || event.type == .keyDown {
                store?.cancelDockPointerInteraction()
            }
            return
        }

        switch event.type {
        case .leftMouseDown:
            // A new pointer sequence supersedes any origin that was not
            // consumed by Bonsplit (for example, a click on an accessory).
            store?.cancelDockPointerInteraction(window: window)
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point),
                  !event.modifierFlags.contains(.control) else {
                return
            }
            // A SwiftUI remount can briefly leave no AppKit hit view at the
            // pointer location. The host's own bounds remain the authoritative
            // Dock region, so only reject a known non-Dock/control hit.
            if let hitView = window.contentView?.hitTest(event.locationInWindow),
               !isDockHitView(hitView, at: event.locationInWindow, in: window) {
                return
            }
            store?.beginUserDockPointerInteraction(window: window)
        case .leftMouseDragged:
            store?.markDockPointerInteractionDragging(window: window)
        case .leftMouseUp:
            store?.releaseDockPointerInteraction(window: window)
        case .keyDown:
            // A released origin that never produced a Bonsplit callback must
            // not survive into a later programmatic selection.
            store?.cancelDockPointerInteraction(window: window)
        default:
            break
        }
    }

    private func isDockHitView(
        _ view: NSView,
        at windowPoint: NSPoint,
        in window: NSWindow
    ) -> Bool {
        // Native accessory controls (close, mute, pin, zoom, and split/new
        // buttons) own their click. They must not turn a metadata action into a
        // Dock keyboard-focus handoff.
        guard !isInteractiveDockChrome(view) else { return false }

        // Bonsplit owns the actual tab-bar AppKit hit regions. This remains
        // correct even when SwiftUI mounts the Dock tab strip in a separate
        // hosting subtree from this monitor view.
        if BonsplitTabItemHitRegionRegistry.containsWindowPoint(
            windowPoint,
            in: window
        ) {
            return true
        }

        guard let store else { return false }
        // Surface portals are intentionally reparented to a window-level host.
        // Resolve their stable panel identity directly from the portal hit
        // registry when available; the root host remains the authoritative Dock
        // ownership region when a portal/tab registry is between remounts.
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
        // portal identity. This host is mounted on the Dock root, so a
        // non-control click inside its bounds is still an explicit Dock
        // interaction even when Bonsplit's geometry registry is remounting.
        return true
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
               control.action != nil,
               current !== view {
                return true
            }
            candidate = current.superview
        }
        return false
    }
}
