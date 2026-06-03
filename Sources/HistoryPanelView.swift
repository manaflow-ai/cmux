import SwiftUI

/// SwiftUI host for ``HistoryPanel``. Renders the closed-item history and wires
/// reopen / delete / clear to the shared ``ClosedItemHistoryStore`` and the
/// app's reopen path.
struct HistoryPanelView: View {
    @ObservedObject var panel: HistoryPanel
    @EnvironmentObject private var tabManager: TabManager
    let isFocused: Bool
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ClosedItemsHistoryView(
            store: ClosedItemHistoryStore.shared,
            onReopen: { [weak tabManager] id in
                _ = AppDelegate.shared?.reopenClosedHistoryItem(id: id, preferredTabManager: tabManager)
            },
            onDelete: { id in
                _ = ClosedItemHistoryStore.shared.removeRecord(id: id)
            },
            onClearAll: { [weak tabManager] in
                AppDelegate.shared?.clearRecentlyClosedHistory(preferredTabManager: tabManager)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.backgroundColor))
        .simultaneousGesture(TapGesture().onEnded { onRequestPanelFocus() })
    }
}
