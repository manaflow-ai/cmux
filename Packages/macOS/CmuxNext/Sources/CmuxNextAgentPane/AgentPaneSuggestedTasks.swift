/// Suggested tasks and nested child chats (cx-lo9yf) on the page: whether agents suggest tasks,
/// the Debug Settings toggle `agent.suggestedTasks` (``AgentPaneTunables/suggestedTasks``).
/// Not an AgentPaneView extension: that type is at its size limit.
public enum AgentPaneSuggestedTasks {
    /// The script that tells a loaded page whether agents suggest tasks.
    static func script(_ on: Bool) -> String {
        "window.cmuxAcpmuxBridge?.applySuggestedTasks?.(\(on));"
    }

    /// Pushes the toggle, read now, to `view`'s page: at each load and handshake, and on each change.
    @MainActor public static func push(to view: AgentPaneView) {
        let on = AgentPaneTunables.suggestedTasks.value
        view.deliver([.suggestedTasks(on)], scripts: [script(on)])
    }
}
