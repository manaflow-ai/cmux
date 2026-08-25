import Foundation

/// The three strings painted together for one realized agent activity label.
struct SidebarAgentActivityDisplayPayload: Equatable, Sendable {
    let text: String
    let toolTip: String?
    let accessibilityLabel: String?

    init(activity: SidebarWorkspaceAgentActivity, at now: Date) {
        guard let state = activity.primaryState else {
            text = ""
            toolTip = nil
            accessibilityLabel = nil
            return
        }

        if state == .running, let elapsed = activity.elapsed(at: now) {
            let elapsedText = SidebarWorkspaceAgentActivity.compactElapsedText(seconds: elapsed)
            text = SidebarWorkspaceAgentActivity.localizedRunningCompactLabel(elapsedText)
            toolTip = SidebarWorkspaceAgentActivity.localizedElapsedTooltip(elapsedText)
            accessibilityLabel = SidebarWorkspaceAgentActivity.localizedRunningAccessibilityLabel(
                elapsedText
            )
            return
        }

        let stateText = SidebarWorkspaceAgentActivity.localizedStateLabel(state)
        text = stateText
        toolTip = state == .unknown
            ? SidebarWorkspaceAgentActivity.localizedUnknownTooltip()
            : stateText
        accessibilityLabel = stateText
    }
}
