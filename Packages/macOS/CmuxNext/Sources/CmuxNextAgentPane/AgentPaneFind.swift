import AppKit

/// Find in Chat: the app's Find, Find Next, Find Previous and Hide Find on an agent pane, sent to
/// the page's find bar as dispatcher commands (as Switch Model and Continue In are).
public struct AgentPaneFind {
    static let commands: Set<String> = ["find", "findNext", "findPrevious", "hideFind"]
    let pane: AgentPaneView

    public init(_ pane: AgentPaneView) {
        self.pane = pane
    }

    /// Runs `command` in the page. `takeFocus` (Cmd-F, the menu, the palette) gives the page the
    /// keyboard, so the bar's field takes it; a socket or CLI run leaves focus alone.
    public func run(_ command: String, takeFocus: Bool) {
        guard Self.commands.contains(command) else { return }
        let webView = pane.webView
        if takeFocus, command != "hideFind", webView.window?.firstResponder !== webView {
            webView.window?.makeFirstResponder(webView)
        }
        pane.deliver([.command(command)], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"\(command)\");"])
    }
}
