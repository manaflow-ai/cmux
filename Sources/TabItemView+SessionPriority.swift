import CMUXAgentLaunch
import SwiftUI

/// The session-priority entries of the sidebar row's context menu, built from
/// the values frozen in the parent-built context-menu snapshot.
extension TabItemView {
    @ViewBuilder
    var sessionPriorityContextMenuSection: some View {
        if snapshot.contextMenu.sessionPriorityEnabled {
            let current = snapshot.contextMenu.claudeDifficultyOverride
            let adjustableManual = snapshot.contextMenu.sessionPriorityAdjustableManual
            Menu(SessionPriorityActions.difficultyMenuTitle) {
                ForEach(Array(SessionPriorityActions.difficultyChoices.enumerated()), id: \.offset) { _, difficulty in
                    Button {
                        actions.applyClaudeDifficulty(difficulty, contextMenuWorkspaceIds)
                    } label: {
                        if difficulty == current {
                            Label(SessionPriorityActions.difficultyTitle(difficulty), systemImage: "checkmark")
                        } else {
                            Text(SessionPriorityActions.difficultyTitle(difficulty))
                        }
                    }
                }
            }
            Button(SessionPriorityActions.manualItemTitle(adjustableManual: adjustableManual)) {
                actions.setSessionPriorityManual(!adjustableManual, contextMenuWorkspaceIds)
            }
            Divider()
        }
    }
}
