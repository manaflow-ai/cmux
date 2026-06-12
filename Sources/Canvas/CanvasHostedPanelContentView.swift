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
        // Inline hosting (cmuxCanvasInlineBrowserHosting) would make webviews
        // track pans frame-perfectly and scale with magnification, but the
        // inline slot mis-lays out under the canvas's flipped document
        // hierarchy (content renders as a small offset rect). Parked behind
        // the default-off environment flag until that layout path is fixed;
        // window-portal hosting with per-frame anchor sync remains.
    }
}
