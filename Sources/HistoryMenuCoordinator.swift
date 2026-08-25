import AppKit
import CmuxWorkspaces
import Observation

/// Owns the immutable projection and action routing for the main History menu.
///
/// Focus and closed-item models remain the sources of truth. This coordinator
/// snapshots them only after a relevant revision/window change or when the menu
/// appears, so high-frequency terminal-title updates cannot rebuild the command
/// graph while menu-open refreshes still present current labels.
@MainActor
@Observable
final class HistoryMenuCoordinator {
    /// Side-effecting History actions supplied by the app composition root.
    struct Actions {
        let reopenMostRecentlyClosedWorkspace: @MainActor (TabManager) -> Bool
        let reopenMostRecentlyClosedItem: @MainActor (TabManager) -> Bool
        let reopenClosedHistoryItem: @MainActor (UUID, TabManager) -> Bool
        let reopenPreviousSession: @MainActor () -> Bool

        /// No-op actions for projection-only tests.
        static let unavailable = Actions(
            reopenMostRecentlyClosedWorkspace: { _ in false },
            reopenMostRecentlyClosedItem: { _ in false },
            reopenClosedHistoryItem: { _, _ in false },
            reopenPreviousSession: { false }
        )
    }

    /// The menu's immutable render state for one active manager.
    struct State: Equatable {
        let managerIdentity: ObjectIdentifier?
        let recentlyFocusedItems: [FocusHistoryMenuItem]
        let recentlyClosed: ClosedItemHistoryMenuSnapshot
        let canNavigateBack: Bool
        let canNavigateForward: Bool

        static let empty = State(
            managerIdentity: nil,
            recentlyFocusedItems: [],
            recentlyClosed: ClosedItemHistoryMenuSnapshot(items: [], totalItemCount: 0, isLimited: false),
            canNavigateBack: false,
            canNavigateForward: false
        )
    }

    private(set) var state = State.empty

    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private let managerProvider: @MainActor () -> TabManager?
    @ObservationIgnored private let closedItemHistoryStore: ClosedItemHistoryStore
    @ObservationIgnored private let actions: Actions
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private weak var projectedManager: TabManager?
    @ObservationIgnored private var projectedFocusHistoryRevision: UInt64?
    @ObservationIgnored private var projectedClosedHistoryRevision: UInt64?

    /// Creates a coordinator with explicit domain and action dependencies.
    init(
        center: NotificationCenter = .default,
        closedItemHistoryStore: ClosedItemHistoryStore,
        managerProvider: @escaping @MainActor () -> TabManager?,
        actions: Actions
    ) {
        self.center = center
        self.closedItemHistoryStore = closedItemHistoryStore
        self.managerProvider = managerProvider
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
    }

    /// Refreshes current labels and closed history when the menu becomes visible.
    func menuWillAppear() {
#if DEBUG
        cmuxDebugLog("history.menu.appear")
#endif
        refreshIfNeeded(forcePresentation: true)
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
            if state != .empty {
                state = .empty
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

        let nextState = State(
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
              state.managerIdentity == ObjectIdentifier(manager),
              state.recentlyFocusedItems.contains(item) else {
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
