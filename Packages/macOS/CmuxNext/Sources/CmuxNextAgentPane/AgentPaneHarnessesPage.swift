/// Integrate a Harness… on a New Tab page (cx-9fqw): the page shows its Harnesses page in place,
/// as its own Integrate a harness button does, instead of the app opening a second tab. Off
/// ``AgentPaneView``, whose type is at its size limit.
public struct AgentPaneHarnessesPage {
    let pane: AgentPaneView

    public init(_ pane: AgentPaneView) {
        self.pane = pane
    }

    /// Shows the Harnesses page in `pane`'s page, with the keyboard there (as Switch Model does).
    @MainActor public func show() {
        pane.focusChat()
        pane.deliver([.command("showHarnesses")], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"showHarnesses\");"])
    }
}
