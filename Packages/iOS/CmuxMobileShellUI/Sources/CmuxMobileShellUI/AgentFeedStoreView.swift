#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// Adapts the observable shell store to the store-free Feed presentation.
/// This is the only agent-feed view that retains a store reference.
struct AgentFeedStoreView: View {
    @Bindable var store: CMUXMobileShellStore
    let items: [MobileAgentFeedItem]
    let status: MobileNotificationFeedStatus
    let pendingReplyRequestIDs: Set<String>

    var body: some View {
        AgentFeedView(
            items: items,
            status: status,
            pendingReplyRequestIDs: pendingReplyRequestIDs,
            refreshesOnAppear: true,
            actions: actions
        )
    }

    private var actions: AgentFeedActions {
        let store = store
        return AgentFeedActions(
            permissionReply: { item, mode in
                Task { await store.submitAgentFeedPermissionReply(item, mode: mode) }
            },
            questionReply: { item, selections in
                Task { await store.submitAgentFeedQuestionReply(item, selections: selections) }
            },
            exitPlanReply: { item, mode, feedback in
                Task { await store.submitAgentFeedExitPlanReply(item, mode: mode, feedback: feedback) }
            },
            terminalReply: { item, text in
                Task { await store.submitAgentFeedTerminalReply(item, text: text) }
            },
            refresh: {
                await store.refreshAgentFeed()
            }
        )
    }
}
#endif
