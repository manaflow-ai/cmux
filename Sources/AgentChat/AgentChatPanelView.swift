import SwiftUI

/// Renders an ``AgentChatPanel`` by mounting its panel-owned webview
/// controller, mirroring the agent-session panel family.
struct AgentChatPanelView: View {
    let panel: AgentChatPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        Group {
            if isVisibleInUI {
                AgentChatWebViewRepresentable(controller: panel.chatViewController)
                    .id(panel.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(Double(portalPriority))
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

/// Hosts the panel-owned ``AgentChatWebViewController`` so the WKWebView and
/// the daemon child survive SwiftUI layout churn; the panel (not this view)
/// owns the controller's lifetime.
private struct AgentChatWebViewRepresentable: NSViewControllerRepresentable {
    let controller: AgentChatWebViewController

    func makeNSViewController(context: Context) -> AgentChatWebViewController {
        controller
    }

    func updateNSViewController(_ nsViewController: AgentChatWebViewController, context: Context) {}
}
