import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings
import WebKit

/// Labs (hq#1980) on the agent pane's own web view (`agent.pageHost` off, the default): the New Tab
/// page and chats get `data-labs` (the flags that are on) and, in nightly and dev builds,
/// `data-labs-team` on `<html>`, as every PageWebView page does: at document start and whenever a
/// flag changes. Kept off ``AgentPaneView``, whose type is at its size limit.
@MainActor
enum AgentPaneLabs {
    private static let views = NSHashTable<WKWebView>.weakObjects()
    private static var observation: Task<Void, Never>?

    /// The pane's document-start scripts: the shared web theme (`window.cmuxTheme`, `--cmux-*`)
    /// and the Labs attributes.
    static func addScripts(to controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: WebTheme.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// `view`, which from now on gets every Labs change.
    static func follow(_ view: AgentPaneWKWebView) -> AgentPaneWKWebView {
        views.add(view)
        if observation == nil {
            // task-owner: app lifetime (panes come and go; the flags do not); event-driven (Observation)
            observation = Task { @MainActor in
                for await _ in ObservationStream({ LabsState.shared.on }) {
                    for view in views.allObjects { view.evaluateJavaScript(script, completionHandler: nil) }
                }
            }
        }
        return view
    }

    /// Flag names are `LabsFlag` raw values (identifiers), so they need no escaping.
    private static var script: String {
        let root = "document.documentElement"
        let team = LabsFlag.teamBuild ? "\(root).setAttribute('data-labs-team','1');" : ""
        return "\(root).setAttribute('data-labs','\(LabsState.shared.on.joined(separator: " "))');" + team
    }
}
