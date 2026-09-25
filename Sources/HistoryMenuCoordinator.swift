import AppKit
import CmuxWorkspaces
import Observation

/// Owns the immutable projection and action routing for the main History menu.
///
/// Focus and closed-item models remain the sources of truth. This coordinator
/// snapshots them only after a relevant revision/window change or when main-menu
/// tracking begins, so high-frequency terminal-title updates cannot rebuild the
/// command graph while menu-open refreshes still present current labels.
@MainActor
@Observable
final class HistoryMenuCoordinator {
    private(set) var state = HistoryMenuState.empty

    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private let managerProvider: @MainActor () -> TabManager?
    @ObservationIgnored private let mainMenuProvider: @MainActor () -> NSMenu?
    @ObservationIgnored private let closedItemHistoryStore: ClosedItemHistoryStore
    @ObservationIgnored private let actions: HistoryMenuActions
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var projectedManager: TabManager?
    @ObservationIgnored private var projectedFocusHistoryRevision: UInt64?
    @ObservationIgnored private var projectedClosedHistoryRevision: UInt64?

    /// Creates a coordinator with explicit domain and action dependencies.
    init(
        center: NotificationCenter = .default,
        closedItemHistoryStore: ClosedItemHistoryStore,
        managerProvider: @escaping @MainActor () -> TabManager?,
        mainMenuProvider: @escaping @MainActor () -> NSMenu?,
        actions: HistoryMenuActions
    ) {
        self.center = center
        self.closedItemHistoryStore = closedItemHistoryStore
        self.managerProvider = managerProvider
        self.mainMenuProvider = mainMenuProvider
        self.actions = actions

        observers.append(center.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter guarantees this closure runs on OperationQueue.main.
            MainActor.assumeIsolated {
                self?.refreshIfNeeded()
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // AppKit key-window notifications are delivered on the main run loop.
            MainActor.assumeIsolated {
                self?.refreshIfNeeded()
            }
        })
        observers.append(center.addObserver(
            forName: .closedItemHistoryRevisionDidChange,
            object: closedItemHistoryStore,
            queue: .main
        ) { [weak self] _ in
            // Closed-item history is MainActor-owned and posts after its revision changes.
            MainActor.assumeIsolated {
                self?.refreshIfNeeded()
            }
        })
        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let trackedMenu = notification.object as? NSMenu else { return }
            var rootMenu = trackedMenu
            while let supermenu = rootMenu.supermenu {
                rootMenu = supermenu
            }
            let trackedRootIdentifier = ObjectIdentifier(rootMenu)
            // NSMenu tracking notifications are delivered on the main run loop.
            MainActor.assumeIsolated {
                guard let self,
                      let mainMenu = self.mainMenuProvider(),
                      ObjectIdentifier(mainMenu) == trackedRootIdentifier else {
                    return
                }
                self.refreshIfNeeded(forcePresentation: true)
            }
        })
    }

    /// Rebuilds only the portions whose manager/revision changed.
    ///
    /// `forcePresentation` re-resolves current titles for menu-open freshness;
    /// equal projections are deliberately not assigned, preventing a redundant
    /// Observation invalidation from re-entering the command graph.
    func refreshIfNeeded(forcePresentation: Bool = false) {
        guard let manager = managerProvider() else {
            projectedManager = nil
            projectedFocusHistoryRevision = nil
            projectedClosedHistoryRevision = nil
            if state != HistoryMenuState.empty {
                state = HistoryMenuState.empty
            }
            return
        }

        let focusHistoryRevision = manager.focusHistoryRevision
        let closedHistoryRevision = closedItemHistoryStore.revision
        let shouldRefreshFocus = forcePresentation
            || projectedManager !== manager
            || projectedFocusHistoryRevision != focusHistoryRevision
        let shouldRefreshClosed = forcePresentation
            || projectedClosedHistoryRevision != closedHistoryRevision
        guard shouldRefreshFocus || shouldRefreshClosed else { return }

        let nextState = HistoryMenuState(
            managerIdentity: ObjectIdentifier(manager),
            recentlyFocusedItems: shouldRefreshFocus
                ? manager.recentlyFocusedFocusHistoryMenuItems(maxItemCount: 10)
                : state.recentlyFocusedItems,
            recentlyClosed: shouldRefreshClosed
                ? closedItemHistoryStore.menuSnapshot(maxItemCount: 10)
                : state.recentlyClosed,
            canNavigateBack: shouldRefreshFocus ? manager.canNavigateBack : state.canNavigateBack,
            canNavigateForward: shouldRefreshFocus ? manager.canNavigateForward : state.canNavigateForward
        )

        projectedManager = manager
        projectedFocusHistoryRevision = focusHistoryRevision
        projectedClosedHistoryRevision = closedHistoryRevision
        if nextState != state {
            state = nextState
        }
    }

    /// Navigates backward in the currently active window's focus history.
    @discardableResult
    func navigateBack() -> Bool {
        activeManagerForAction()?.navigateBack() == true
    }

    /// Navigates forward in the currently active window's focus history.
    @discardableResult
    func navigateForward() -> Bool {
        activeManagerForAction()?.navigateForward() == true
    }

    /// Navigates to a row only when it still belongs to the projected manager.
    @discardableResult
    func navigate(to item: FocusHistoryMenuItem) -> Bool {
        guard let manager = activeManagerForAction(),
              projectedManager === manager,
              state.managerIdentity == ObjectIdentifier(manager) else {
            return false
        }
        return manager.navigateToFocusHistoryMenuItem(item)
    }

    /// Reopens the most recently closed workspace into the active manager.
    @discardableResult
    func reopenMostRecentlyClosedWorkspace() -> Bool {
        guard let manager = activeManagerForAction() else { return false }
        return actions.reopenMostRecentlyClosedWorkspace(manager)
    }

    /// Reopens the most recently closed item into the active manager.
    @discardableResult
    func reopenMostRecentlyClosedItem() -> Bool {
        guard let manager = activeManagerForAction() else { return false }
        return actions.reopenMostRecentlyClosedItem(manager)
    }

    /// Reopens a specific closed-history row into the active manager.
    @discardableResult
    func reopenClosedHistoryItem(id: UUID) -> Bool {
        guard let manager = activeManagerForAction() else { return false }
        return actions.reopenClosedHistoryItem(id, manager)
    }

    /// Restores the previous app launch through the app-owned action path.
    @discardableResult
    func reopenPreviousSession() -> Bool {
        actions.reopenPreviousSession()
    }

    /// Resolves the active manager and refreshes before any cross-window action.
    private func activeManagerForAction() -> TabManager? {
        let manager = managerProvider()
        if projectedManager !== manager {
            refreshIfNeeded(forcePresentation: true)
        }
        return manager
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }
}
