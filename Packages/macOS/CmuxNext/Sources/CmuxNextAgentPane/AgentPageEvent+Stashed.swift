import CmuxNextSettings

extension AgentPageEvent {
    /// How many tabs are stashed (`stashedCount`): the New Tab page shows its Stashed link
    /// while it is above zero.
    public static func stashedCount(_ count: Int) -> AgentPageEvent {
        AgentPageEvent(kind: "stashedCount", value: .number(Double(max(0, count))))
    }

    /// Pushes the stash count to `view`'s page (not an AgentPaneView extension: that type is at its size limit).
    @MainActor public static func pushStashedCount(_ count: Int, to view: AgentPaneView) {
        let event = stashedCount(count)
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applyStashedCount?.(\(max(0, count)));"])
    }
}
