import SwiftUI

/// SwiftUI host for ``HistoryPanel``. Renders the shared ``SessionIndexView`` and
/// wires its resume and delete actions to the workspace's tab manager and the
/// pane's session store.
struct HistoryPanelView: View {
    @ObservedObject var panel: HistoryPanel
    @EnvironmentObject private var tabManager: TabManager
    let isFocused: Bool
    let isVisibleInUI: Bool
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        SessionIndexView(
            store: panel.sessionIndexStore,
            onResume: { entry in
                SessionEntryResumeCoordinator.resume(entry, tabManager: tabManager)
            },
            onDelete: { [weak panel] entry in
                panel?.sessionIndexStore.delete(entry)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.backgroundColor))
        .simultaneousGesture(TapGesture().onEnded { requestPanelFocusIfNeeded() })
    }

    private func requestPanelFocusIfNeeded() {
        guard !panel.isFocusedInWorkspace else { return }
        onRequestPanelFocus()
    }
}
