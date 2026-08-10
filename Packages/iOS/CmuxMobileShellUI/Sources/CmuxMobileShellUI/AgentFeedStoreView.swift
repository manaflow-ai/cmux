#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// The only agent-feed view that retains the observable shell store.
struct AgentFeedStoreView: View {
    @Bindable var store: CMUXMobileShellStore
    private let localizer = AgentFeedLocalizer()
    @State private var filter: MobileAgentFeedFilter = .needsInput

    var body: some View {
        AgentFeedView(
            items: store.agentFeedItems,
            status: store.agentFeedStatus,
            filter: $filter,
            drafts: store.agentFeedDrafts,
            mutationStates: store.agentFeedMutationStates,
            hasMoreItems: store.agentFeedHasMoreItems,
            canLoadOlder: store.agentFeedCanLoadOlder,
            isLoadingOlder: store.agentFeedIsLoadingOlder,
            actions: AgentFeedActions(
                setDraft: { id, value in store.agentFeedDrafts[id] = value },
                reply: { item in Task { await store.sendAgentFeedReply(for: item) } },
                decide: { item, action in Task { await store.sendAgentFeedAction(action, for: item) } },
                open: { item in Task { _ = await store.openAgentFeedItem(item) } },
                refresh: { Task { await store.refreshAgentFeed() } },
                loadOlder: { Task { await store.loadOlderAgentFeed() } },
                recordTopRowAppearance: { _ in }
            )
        )
        .environment(\.agentFeedLocalizer, localizer)
    }
}
#endif
