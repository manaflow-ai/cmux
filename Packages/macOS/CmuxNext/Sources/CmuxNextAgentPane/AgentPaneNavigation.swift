import CmuxNextPages
import Foundation

/// Keeps the agent page on its document (`PageWebView.onNavigate`, AgentPaneView+PageHost): a
/// clicked http(s) link, or a cmux app link (opened in the app), opens outside the pane after a
/// real user gesture (``openOutside(_:gestures:open:openApp:)``); a frame inside the page may show
/// a loopback web page (a turn's preview card, `URL.isAgentPanePreview`) or the render frame (a
/// render card, `AgentPaneRenderFrame`); every other navigation is cancelled.
enum AgentPaneNavigation {
    enum Decision: Equatable {
        case allow
        case openOutside(URL)
        case cancel
    }

    static func decision(for url: URL?, source: AgentPaneSource, userClicked: Bool, mainFrame: Bool = true) -> Decision {
        guard let url else { return .cancel }
        if mainFrame, source.isTrusted(url) { return .allow }
        // A preview frame stays on loopback pages; a click inside it does not leave the frame.
        if !mainFrame {
            if AgentPaneRenderFrame.isFrame(url) { return .allow }
            // A question's HTML option preview (question/HtmlPreview.tsx): the pane's own
            // document, written into a sandboxed frame with no scripts. It loads nothing itself.
            if url.absoluteString == "about:srcdoc" { return .allow }
            return url.isAgentPanePreview && !source.isTrusted(url) ? .allow : .cancel
        }
        if userClicked, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return .openOutside(url) }
        if userClicked, isCmuxAppLink(url) { return .openOutside(url) }
        return .cancel
    }
}
