import AppKit
import Bonsplit

/// Carries a user-originated Dock pointer interaction across AppKit and
/// Bonsplit callbacks without relying on the process-wide current event or a
/// scheduling turn.
@MainActor
final class DockPointerInteractionCoordinator {
    enum Phase: Equatable {
        case idle
        case pressed
        case dragging
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

    /// Records that the pointer crossed into a tab drag.
    func markDragging(in window: NSWindow?) {
        guard phase == .pressed, matches(window: window) else { return }
        phase = .dragging
    }

    /// Retains the transaction after mouse-up so a delayed Bonsplit selection
    /// callback can still consume its explicit user origin.
    func markReleased(in window: NSWindow?) {
        guard (phase == .pressed || phase == .dragging), matches(window: window) else {
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
    /// correct window-scoped coordinator. A drag is allowed to consume even
    /// when Bonsplit reports the same selection identity during reparenting.
    func consumeSelection(
        in window: NSWindow?,
        paneID: PaneID,
        tabID: TabID
    ) -> NSWindow? {
        guard phase != .idle, matches(window: window) else { return nil }
        let selectionChanged = initialPaneID != paneID || initialTabID != tabID
        guard selectionChanged || phase == .dragging else { return nil }
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
            initialTabID: selection.map { TabID(uuid: $0.tab.id) }
        )
        noteKeyboardFocusIntent(window: window)
    }

    /// Advances a Dock pointer transaction into its drag phase.
    func markDockPointerInteractionDragging(window: NSWindow?) {
        guard isVisibleInUI, scope == .global else { return }
        dockPointerInteractionCoordinator.markDragging(in: window)
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
            tab: TabID(uuid: tab.id),
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
            tab: TabID(uuid: tab.id),
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
            tab: TabID(uuid: tab.id),
            window: nil
        )
        scheduleDockPortalReconcile(reason: "dock.moveTab")
    }
}
