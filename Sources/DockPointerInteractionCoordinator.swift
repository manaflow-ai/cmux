import AppKit
import Bonsplit

enum DockPointerHitTarget: Equatable {
    case tabItem
    case panel
}

/// Pure policy for turning AppKit hit-test signals into Dock ownership. The
/// geometry/portal lookups stay in the host view, while this bounded decision
/// is executable in unit tests without constructing a Bonsplit hierarchy.
struct DockPointerHitSignals: Equatable, Sendable {
    let registryTabItemHit: Bool
    let hierarchyTabItemHit: Bool
    let interactiveChromeHit: Bool
    let selectedPanelHit: Bool

    var target: DockPointerHitTarget? {
        if registryTabItemHit || hierarchyTabItemHit {
            return interactiveChromeHit ? nil : .tabItem
        }
        return selectedPanelHit ? .panel : nil
    }
}

/// Delivers Dock pointer events through one process-wide AppKit monitor.
/// `NSEvent.addLocalMonitorForEvents` is application-scoped, so installing one
/// monitor per visible Dock makes every click fan out through every window's
/// hit-test tree. This router keeps a single window-to-host index and invokes
/// only the host that owns the event's window.
@MainActor
final class DockPointerInteractionEventRouter {
    private struct Entry {
        weak var host: DockPointerInteractionHostView?
    }

    /// Hosts are kept in mount order so a transient SwiftUI overlap can fall
    /// back to the older live host when the newer one is dismantled.
    private var hostsByWindow: [ObjectIdentifier: [Entry]] = [:]
    private var eventMonitor: Any?

    init() {}

    func register(_ host: DockPointerInteractionHostView, in window: NSWindow) {
        pruneDeadHosts()
        let hostID = ObjectIdentifier(host)
        // A SwiftUI representable can migrate between windows. Remove any old
        // registration for this host before installing its new owner window.
        for key in Array(hostsByWindow.keys) {
            hostsByWindow[key]?.removeAll { entry in
                guard let registeredHost = entry.host else { return true }
                return ObjectIdentifier(registeredHost) == hostID
            }
            if hostsByWindow[key]?.isEmpty == true {
                hostsByWindow.removeValue(forKey: key)
            }
        }
        hostsByWindow[ObjectIdentifier(window), default: []].append(
            Entry(host: host)
        )
        installMonitorIfNeeded()
    }

    func isRegistered(
        _ host: DockPointerInteractionHostView,
        in window: NSWindow
    ) -> Bool {
        hostsByWindow[ObjectIdentifier(window)]?.contains { entry in
            entry.host === host
        } == true
    }

    func unregister(_ host: DockPointerInteractionHostView) {
        unregister(hostID: ObjectIdentifier(host), in: nil)
    }

    /// Stable-identity variant used by teardown closures that may run while a
    /// host is being deallocated and therefore cannot capture `self` strongly.
    func unregister(hostID: ObjectIdentifier, in window: NSWindow?) {
        let windowID = window.map(ObjectIdentifier.init)
        for key in Array(hostsByWindow.keys) {
            if let windowID, key != windowID {
                continue
            }
            hostsByWindow[key]?.removeAll { entry in
                guard let registeredHost = entry.host else { return true }
                return ObjectIdentifier(registeredHost) == hostID
            }
            if hostsByWindow[key]?.isEmpty == true {
                hostsByWindow.removeValue(forKey: key)
            }
        }
        pruneDeadHosts()
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .leftMouseDown,
                .leftMouseUp,
                .rightMouseDown,
                .rightMouseUp,
                .otherMouseDown,
                .otherMouseUp,
            ]
        ) { [weak self] event in
            self?.route(event)
            return event
        }
    }

    private func route(_ event: NSEvent) {
        guard let window = event.window else { return }
        pruneDeadHosts()
        guard let host = hostsByWindow[ObjectIdentifier(window)]?
            .reversed()
            .compactMap(\.host)
            .first else {
            return
        }
        host.handlePointerEvent(event)
    }

    private func pruneDeadHosts() {
        var liveHostsByWindow: [ObjectIdentifier: [Entry]] = [:]
        for (windowID, entries) in hostsByWindow {
            let liveEntries = entries.filter { $0.host != nil }
            if !liveEntries.isEmpty {
                liveHostsByWindow[windowID] = liveEntries
            }
        }
        hostsByWindow = liveHostsByWindow
        guard hostsByWindow.isEmpty, let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}

/// Carries a user-originated Dock pointer interaction across AppKit and
/// Bonsplit callbacks without relying on the process-wide current event or a
/// scheduling turn.
@MainActor
final class DockPointerInteractionCoordinator {
    enum Phase: Equatable {
        case idle
        case pressed
        case released
    }

    private(set) var phase: Phase = .idle
    private weak var originWindow: NSWindow?
    private var originWindowID: ObjectIdentifier?
    private var initialPaneID: PaneID?
    private var initialTabID: TabID?

    /// Starts a pointer transaction at the Dock boundary.
    func begin(
        window: NSWindow?,
        initialPaneID: PaneID?,
        initialTabID: TabID?
    ) {
        guard let window else {
            cancel()
            return
        }
        originWindow = window
        originWindowID = ObjectIdentifier(window)
        self.initialPaneID = initialPaneID
        self.initialTabID = initialTabID
        phase = .pressed
    }

    /// Retains the transaction after mouse-up so Bonsplit's tap callback can
    /// consume the explicit user origin even when delivery is delayed.
    func markReleased(in window: NSWindow?) {
        guard phase == .pressed, matches(window: window) else {
            return
        }
        phase = .released
    }

    /// Cancels an unconsumed transaction at a real lifecycle boundary.
    func cancel(in window: NSWindow? = nil) {
        guard window == nil || matches(window: window) else { return }
        phase = .idle
        originWindow = nil
        originWindowID = nil
        initialPaneID = nil
        initialTabID = nil
    }

    /// Consumes the origin for a selection callback whose pane/tab changed.
    /// Returns the originating window so the caller can publish focus to the
    /// correct window-scoped coordinator.
    func consumeSelection(
        in window: NSWindow?,
        paneID: PaneID,
        tabID: TabID
    ) -> NSWindow? {
        guard phase != .idle, matches(window: window) else { return nil }
        // An empty-pane click has no tab identity to bind to. Never let a
        // later programmatic selection consume that unbound origin.
        guard initialPaneID != nil || initialTabID != nil else {
            cancel()
            return nil
        }
        let selectionChanged = initialPaneID != paneID || initialTabID != tabID
        guard selectionChanged else {
            // A released callback that reports the original selection is the
            // terminal callback for this pointer sequence. Keeping it alive
            // would let a later programmatic reselection consume the origin.
            if phase == .released {
                cancel()
            }
            return nil
        }
        let owner = originWindow ?? window
        cancel()
        return owner
    }

    private func matches(window: NSWindow?) -> Bool {
        guard let originWindowID else { return false }
        guard let window else { return true }
        return ObjectIdentifier(window) == originWindowID
    }
}

extension DockSplitStore {
    /// Begins a user-originated Dock pointer transaction and publishes the
    /// owning window's Dock focus immediately, before Bonsplit selection.
    func beginUserDockPointerInteraction(window: NSWindow?) {
        guard isVisibleInUI, scope == .global else { return }
        let selection = focusedDockSurfaceSelection()
        dockPointerInteractionCoordinator.begin(
            window: window,
            initialPaneID: selection?.paneId,
            initialTabID: selection?.tab.id
        )
        noteKeyboardFocusIntent(window: window)
    }

    /// Retains a Dock pointer origin after mouse-up for delayed Bonsplit
    /// callbacks; the next unrelated pointer/key/lifecycle event cancels it.
    func releaseDockPointerInteraction(window: NSWindow?) {
        dockPointerInteractionCoordinator.markReleased(in: window)
    }

    /// Cancels an unconsumed Dock pointer origin at a real event/lifecycle
    /// boundary rather than using a wall-clock or actor-turn timeout.
    func cancelDockPointerInteraction(window: NSWindow? = nil) {
        dockPointerInteractionCoordinator.cancel(in: window)
    }

    /// Consumes a user-originated selection and publishes focus to its owner.
    @discardableResult
    func consumeDockPointerSelection(
        pane: PaneID,
        tab: TabID,
        window: NSWindow?
    ) -> Bool {
        guard let owner = dockPointerInteractionCoordinator.consumeSelection(
            in: window,
            paneID: pane,
            tabID: tab
        ) else {
            return false
        }
        noteKeyboardFocusIntent(window: owner)
        return true
    }

    func splitTabBar(
        _ controller: BonsplitController,
        didSelectTab tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) {
        applyDockSelection(tabId: tab.id, inPane: pane)
        _ = consumeDockPointerSelection(
            pane: pane,
            tab: tab.id,
            window: nil
        )
    }

    func splitTabBar(
        _ controller: BonsplitController,
        didFocusPane pane: PaneID
    ) {
        guard let tab = controller.selectedTab(inPane: pane) else {
            // Pane focus can legitimately land on an empty pane while a split
            // is being assembled. Keep menu validation in sync with that state.
            refreshDockMenuCapabilities()
            applyVisibilityToAllPanels()
            return
        }
        applyDockSelection(tabId: tab.id, inPane: pane)
        _ = consumeDockPointerSelection(
            pane: pane,
            tab: tab.id,
            window: nil
        )
    }

    /// Mirrors the main workspace's move callback while preserving the
    /// explicit user-origin transaction for delayed drag delivery.
    func splitTabBar(
        _ controller: BonsplitController,
        didMoveTab tab: Bonsplit.Tab,
        fromPane _: PaneID,
        toPane destination: PaneID
    ) {
        // Bonsplit auto-closes an emptied source pane during a cross-pane move
        // without emitting `didClosePane`, so this callback must reconcile the
        // full ownership snapshot.
        synchronizeOwnedPaneIds(with: controller)
        applyDockSelection(tabId: tab.id, inPane: destination)
        let movedPanel = panel(for: tab.id)
        (movedPanel as? TerminalPanel)?.recordPortalHostOwnershipChange()
        if let deferredPanel = movedPanel as? DeferredBrowserPanel {
            _ = requestDeferredBrowserMaterialization(
                panelId: deferredPanel.id,
                isVisibleInUI: true,
                reason: "dock.moveTab"
            )
        } else {
            movedPanel?.focus()
        }
        _ = consumeDockPointerSelection(
            pane: destination,
            tab: tab.id,
            window: nil
        )
        scheduleDockPortalReconcile(reason: "dock.moveTab")
    }
}
