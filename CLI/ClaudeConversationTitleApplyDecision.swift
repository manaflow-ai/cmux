struct ClaudeConversationTitleApplyDecision {
    var shouldRenameWorkspace: Bool
    var shouldRenameTab: Bool

    var shouldApply: Bool {
        shouldRenameWorkspace || shouldRenameTab
    }
}
