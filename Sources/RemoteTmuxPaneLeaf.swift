import Bonsplit
import SwiftUI

/// One pane leaf: the terminal panel, chrome-free. Pane actions live in its
/// context menu and active-pane state is shown on the adjacent divider strips.
@MainActor
struct RemoteTmuxPaneLeaf: View {
    let paneId: Int
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onClosePane: (Int) -> Void

    var body: some View {
        if let panel = mirror.panel(forPane: paneId),
           let syntheticPaneId = mirror.syntheticPaneID(forPane: paneId) {
            TerminalPanelView(
                panel: panel,
                paneId: syntheticPaneId,
                isFocused: mirror.activePaneId == paneId,
                isVisibleInUI: isVisibleInUI,
                portalPriority: portalPriority,
                isSplit: true,
                appearance: appearance,
                hasUnreadNotification: false,
                terminalAgentContext: "",
                onFocus: { mirror.focus(pane: paneId) },
                onResumeAgentHibernation: {},
                onAutoResumeAgentHibernation: {},
                onTriggerFlash: {}
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu {
                Button(String(localized: "remoteTmux.pane.splitRight", defaultValue: "Split Right")) {
                    mirror.requestSplit(fromPane: paneId, vertical: false)
                }
                Button(String(localized: "remoteTmux.pane.splitDown", defaultValue: "Split Down")) {
                    mirror.requestSplit(fromPane: paneId, vertical: true)
                }
                Divider()
                Button(String(localized: "remoteTmux.pane.close", defaultValue: "Close Pane"), role: .destructive) {
                    onClosePane(paneId)
                }
            }
            .id(paneId)
            .background(Color(nsColor: appearance.backgroundColor))
        } else {
            Color(nsColor: appearance.backgroundColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
