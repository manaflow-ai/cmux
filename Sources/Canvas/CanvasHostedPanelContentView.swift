import CmuxPanes
import SwiftUI
import Bonsplit

/// SwiftUI fallback content for canvas panes whose panel kind is not yet
/// direct-hosted (browser, markdown, file preview, agent session, ...).
///
/// Reuses the exact split-mode panel views so behavior stays shared; the
/// known v1 caveat is that window-portal content inside these views clips by
/// resizing at the viewport edge instead of cropping.
struct CanvasHostedPanelContentView: View {
    let panel: any Panel
    let workspaceId: UUID
    let paneId: PaneID
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        PanelContentView(
            panel: panel,
            workspaceId: workspaceId,
            paneId: paneId,
            isFocused: isFocused,
            isSelectedInPane: true,
            isVisibleInUI: isVisibleInUI,
            portalPriority: portalPriority,
            isSplit: false,
            appearance: appearance,
            hasUnreadNotification: false,
            terminalAgentContext: "",
            onFocus: onRequestPanelFocus,
            onRequestPanelFocus: onRequestPanelFocus,
            onResumeAgentHibernation: {},
            onAutoResumeAgentHibernation: {},
            onTriggerFlash: {}
        )
        // Window-portal content (webviews) floats above the pane's layer
        // border; this inset keeps the focus ring visible around it.
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
        // Inline hosting parents the webview inside the pane hierarchy: pans
        // track frame-perfectly (no window-portal trailing), content scales
        // with magnification, and z-order is native. Default-on; the
        // launch-time default `canvasInlineBrowserHostingDisabled` is the
        // escape hatch back to window-portal hosting.
        .environment(
            \.cmuxCanvasInlineBrowserHosting,
            !UserDefaults.standard.bool(forKey: "canvasInlineBrowserHostingDisabled")
        )
    }
}
