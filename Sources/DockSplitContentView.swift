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

/// Supplies an explicit, Dock-scoped pointer token to ``DockSplitStore`` before
/// Bonsplit emits its selection callbacks. Bonsplit also emits those callbacks
/// for programmatic mutations, so a callback must never infer user intent from
/// the process-wide current event.
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
    private var globalMouseUpMonitor: Any?
    private var windowResignKeyObserver: NSObjectProtocol?
    private var deferredInteractionClearTask: Task<Void, Never>?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A SwiftUI host can migrate between windows while retaining this
        // representable. Rebind the monitor/observer to the new window rather
        // than leaving a token tied to the old one.
        stopMonitoring()
        installMonitorIfNeeded()
    }

    func installMonitorIfNeeded() {
        guard window != nil, eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .leftMouseUp,
                .rightMouseUp,
                .otherMouseUp,
            ]
        ) { [weak self] event in
            self?.handle(event: event)
            return event
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] _ in
            // A drag can leave the app before mouse-up is delivered to the
            // local monitor. Clear on the next MainActor turn so a SwiftUI
            // TapGesture handling an in-app mouse-up gets to consume the token.
            self?.scheduleInteractionClear()
        }
        if windowResignKeyObserver == nil, let window {
            windowResignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.cancelInteractionClear()
                self?.store?.endUserDockInteraction()
            }
        }
    }

    func stopMonitoring() {
        cancelInteractionClear()
        store?.endUserDockInteraction()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
        if let windowResignKeyObserver {
            NotificationCenter.default.removeObserver(windowResignKeyObserver)
            self.windowResignKeyObserver = nil
        }
    }

    private func handle(event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let window, event.window === window else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else {
                cancelInteractionClear()
                store?.endUserDockInteraction()
                return
            }
            cancelInteractionClear()
            store?.beginUserDockInteraction()
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // SwiftUI's TapGesture invokes Bonsplit selection from the same
            // mouse-up after local monitors run. Defer clearing one MainActor
            // turn so that callback can consume the explicit token; the global
            // monitor and window-resign observer cover releases outside the app.
            scheduleInteractionClear()
        default:
            break
        }
    }

    private func scheduleInteractionClear() {
        deferredInteractionClearTask?.cancel()
        deferredInteractionClearTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.store?.endUserDockInteraction()
            self.deferredInteractionClearTask = nil
        }
    }

    private func cancelInteractionClear() {
        deferredInteractionClearTask?.cancel()
        deferredInteractionClearTask = nil
    }
}
