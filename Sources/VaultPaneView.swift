import SwiftUI

/// Thin mount adapter. The complete History surface, including its mode,
/// filter, search, loading, empty, and virtualized list UI, lives in AppKit.
struct VaultPaneView: NSViewControllerRepresentable {
    let tabManager: TabManager
    let store: SessionIndexStore
    let closedItemStore: ClosedItemHistoryStore
    let onResume: ((SessionEntry) -> Void)?
    let onReopenClosedItem: ((UUID) -> Bool)?

    func makeNSViewController(context: Context) -> VaultHistoryViewController {
        _ = context
        let controller = VaultHistoryViewController(
            tabManager: tabManager,
            sessionStore: store,
            closedItemStore: closedItemStore,
            log: .shared,
            onResume: onResume,
            onReopenClosedItem: onReopenClosedItem
        )
        controller.start()
        return controller
    }

    func updateNSViewController(
        _ controller: VaultHistoryViewController,
        context: Context
    ) {
        _ = context
        controller.updateCallbacks(
            onResume: onResume,
            onReopenClosedItem: onReopenClosedItem
        )
    }

    static func dismantleNSViewController(
        _ controller: VaultHistoryViewController,
        coordinator: Void
    ) {
        _ = coordinator
        controller.stop()
    }
}
