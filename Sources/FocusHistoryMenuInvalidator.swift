import AppKit
import Combine
import CmuxWorkspaces
import SwiftUI

@MainActor
final class FocusHistoryMenuInvalidator: ObservableObject {
    struct State: Equatable {
        let managerIdentity: ObjectIdentifier?
        let recentlyFocused: FocusHistoryMenuSnapshot
        let recentlyClosed: ClosedItemHistoryMenuSnapshot
        let canNavigateBack: Bool
        let canNavigateForward: Bool

        static let empty = State(
            managerIdentity: nil,
            recentlyFocused: FocusHistoryMenuSnapshot(items: [], totalItemCount: 0, isLimited: false),
            recentlyClosed: ClosedItemHistoryMenuSnapshot(items: [], totalItemCount: 0, isLimited: false),
            canNavigateBack: false,
            canNavigateForward: false
        )
    }

    /// The immutable command projection. It changes only when the active
    /// manager or its focus-history revision changes, so unrelated workspace
    /// observations cannot invalidate the History command graph.
    @Published private(set) var state = State.empty

    private let center: NotificationCenter
    private let managerProvider: @MainActor () -> TabManager?
    private let closedItemHistoryStore: ClosedItemHistoryStore
    private var observers: [NSObjectProtocol] = []
    private var closedHistoryCancellable: AnyCancellable?
    private weak var cachedManager: TabManager?
    private var cachedFocusHistoryRevision: UInt64?
    private var cachedClosedHistoryRevision: UInt64?

    init(
        center: NotificationCenter = .default,
        closedItemHistoryStore: ClosedItemHistoryStore = .shared,
        managerProvider: @escaping @MainActor () -> TabManager? = {
            AppDelegate.shared?.activeTabManagerForCommands(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }
    ) {
        self.center = center
        self.closedItemHistoryStore = closedItemHistoryStore
        self.managerProvider = managerProvider
        observers.append(center.addObserver(
            forName: .tabManagerFocusHistoryRevisionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshIfNeeded()
            }
        })
        closedHistoryCancellable = closedItemHistoryStore.$revision.sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshIfNeeded()
            }
        }
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshIfNeeded()
            }
        })
    }

    /// Rebuilds the projection once for a new active-manager/revision pair.
    /// Equal projections are intentionally not published: publishing an
    /// unchanged value would re-enter SwiftUI's command graph and recreate the
    /// main-menu invalidation cycle this cache is designed to break.
    func refreshIfNeeded() {
        guard let manager = managerProvider() else {
            cachedManager = nil
            cachedFocusHistoryRevision = nil
            cachedClosedHistoryRevision = nil
            if state != .empty {
                state = .empty
            }
            return
        }

        let revision = manager.focusHistoryRevision
        let closedHistoryRevision = closedItemHistoryStore.revision
        guard cachedManager !== manager
            || cachedFocusHistoryRevision != revision
            || cachedClosedHistoryRevision != closedHistoryRevision else {
            return
        }

        let shouldRefreshFocusHistory = cachedManager !== manager || cachedFocusHistoryRevision != revision
        let recentlyFocused: FocusHistoryMenuSnapshot
        let canNavigateBack: Bool
        let canNavigateForward: Bool
        if shouldRefreshFocusHistory {
            let items = manager.recentlyFocusedFocusHistoryMenuItems(maxItemCount: 10)
            recentlyFocused = FocusHistoryMenuSnapshot(
                items: items,
                totalItemCount: items.count,
                isLimited: items.count == 10
            )
            canNavigateBack = manager.canNavigateBack
            canNavigateForward = manager.canNavigateForward
        } else {
            recentlyFocused = state.recentlyFocused
            canNavigateBack = state.canNavigateBack
            canNavigateForward = state.canNavigateForward
        }
        let nextState = State(
            managerIdentity: ObjectIdentifier(manager),
            recentlyFocused: recentlyFocused,
            recentlyClosed: closedItemHistoryStore.menuSnapshot(maxItemCount: 10),
            canNavigateBack: canNavigateBack,
            canNavigateForward: canNavigateForward
        )

        cachedManager = manager
        cachedFocusHistoryRevision = revision
        cachedClosedHistoryRevision = closedHistoryRevision
        if nextState != state {
            state = nextState
        }
    }

    deinit {
        for observer in observers {
            center.removeObserver(observer)
        }
    }
}
