import Bonsplit
import SwiftUI

@MainActor
struct RemoteTmuxWindowMirrorSplitView: View {
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isOuterFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onOuterFocus: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var containerSize: CGSize = .zero

    var body: some View {
        BonsplitView(controller: mirror.bonsplitController) { tab, paneId in
            if let tmuxPaneId = mirror.tmuxPaneId(forTab: tab.id),
               let panel = mirror.panel(forPane: tmuxPaneId) {
                TerminalPanelView(
                    panel: panel,
                    paneId: paneId,
                    isFocused: isOuterFocused && mirror.isFocused(tabId: tab.id),
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: portalPriority,
                    isSplit: true,
                    appearance: appearance,
                    hasUnreadNotification: false,
                    terminalAgentContext: "",
                    onFocus: {
                        onOuterFocus()
                        mirror.setActivePane(tmuxPaneId, fromTmux: false)
                    },
                    onResumeAgentHibernation: {},
                    onAutoResumeAgentHibernation: {},
                    onTriggerFlash: {}
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture {
                    onOuterFocus()
                    mirror.bonsplitController.focusPane(paneId)
                }
            } else {
                Color(nsColor: appearance.backgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } emptyPane: { _ in
            Color(nsColor: appearance.backgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .internalOnlyTabDrag()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.backgroundColor))
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            containerSize = newSize
            pushClientSize(pointSize: newSize)
        }
        .onAppear {
            mirror.isVisibleForSizing = isVisibleInUI
            if isVisibleInUI { pushClientSize(pointSize: containerSize) }
        }
        .onChange(of: isVisibleInUI) { _, visible in
            mirror.isVisibleForSizing = visible
            if visible { pushClientSize(pointSize: containerSize) }
        }
        .onChange(of: mirror.layoutStructureVersion) { _, _ in
            pushClientSize(pointSize: containerSize)
        }
    }

    private func pushClientSize(pointSize: CGSize) {
        mirror.isVisibleForSizing = isVisibleInUI
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        mirror.noteContainerSize(pointSize: pointSize, scale: displayScale)
        _ = mirror.updateClientSize()
    }
}
