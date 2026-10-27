import CmuxNextPages
import Foundation

/// Keeps the agent page on its document (`PageWebView.onNavigate`, AgentPaneView+PageHost). The
/// page host decides the page's own origin itself (``PageNavigation/policy(for:page:userClicked:mainFrame:hook:)``:
/// the main frame stays on the entry document, and a frame may load the origin's documents, such
/// as the render frame, `AgentPaneRenderFrame`), so this decides only other URLs: a clicked
/// http(s) link, or a cmux app link (opened in the app), opens outside the pane after a real user
/// gesture (``openOutside(_:gestures:open:openApp:)``); a frame inside the page may show a loopback
/// web page (a turn's preview card, `URL.isAgentPanePreview`); every other navigation is cancelled.
enum AgentPaneNavigation {
    enum Decision: Equatable {
        case allow
        case openOutside(URL)
        case cancel
    }

    static func decision(for url: URL?, userClicked: Bool, mainFrame: Bool = true) -> Decision {
        guard let url else { return .cancel }
        // A preview frame stays on loopback pages; a click inside it does not leave the frame.
        if !mainFrame {
            // A question's HTML option preview (question/HtmlPreview.tsx): the pane's own
            // document, written into a sandboxed frame with no scripts. It loads nothing itself.
            if url.absoluteString == "about:srcdoc" { return .allow }
            return url.isAgentPanePreview ? .allow : .cancel
        }
        if userClicked, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" { return .openOutside(url) }
        if userClicked, isCmuxAppLink(url) { return .openOutside(url) }
        return .cancel
    }
}
