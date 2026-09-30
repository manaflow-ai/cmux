#if os(iOS)
import CMUXMobileCore
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
    let pendingTerminalReplyItemIDs: Set<MobileAgentFeedItemID>
    var isActive = true

    @State private var showsNavigationFailure = false
    @State private var isFeedVisible = false
    @Bindable var searchCoordinator: MobilePrimarySearchCoordinator

    var body: some View {
        AgentFeedView(
            items: items,
            status: status,
            pendingReplyRequestIDs: pendingReplyRequestIDs,
            pendingTerminalReplyItemIDs: pendingTerminalReplyItemIDs,
            failedTerminalReplies: store.agentFeedFailedTerminalReplies,
            refreshesOnAppear: isActive,
            isActive: isActive,
            actions: actions,
            searchText: searchCoordinator.searchDestinationText(for: .feed)
        )
        .onAppear {
            updateFeedVisibility(isActive)
        }
        .onChange(of: isActive) { _, active in
            updateFeedVisibility(active)
        }
        .onDisappear {
            updateFeedVisibility(false)
        }
        .alert(String(localized: "mobile.agentFeed.openFailed.title", defaultValue: "Couldn’t open event", bundle: .module),
               isPresented: $showsNavigationFailure) {
            Button(String(localized: "mobile.agentFeed.fullText.close", defaultValue: "Close", bundle: .module), role: .cancel) {}
        } message: {
            Text(String(localized: "mobile.agentFeed.openFailed.message",
                        defaultValue: "The event’s computer, workspace, or tab is no longer available.", bundle: .module))
        }
    }

    private var actions: AgentFeedActions {
        let store = store
        return AgentFeedActions(
            permissionReply: { item, mode in
                store.markAgentFeedItemInteracted(item)
                Task { await store.submitAgentFeedPermissionReply(item, mode: mode) }
            },
            questionReply: { item, selections in
                store.markAgentFeedItemInteracted(item)
                Task { await store.submitAgentFeedQuestionReply(item, selections: selections) }
            },
            exitPlanReply: { item, mode, feedback in
                store.markAgentFeedItemInteracted(item)
                Task { await store.submitAgentFeedExitPlanReply(item, mode: mode, feedback: feedback) }
            },
            terminalReply: { item, text in
                store.markAgentFeedItemInteracted(item)
                Task {
                    if await store.submitAgentFeedTerminalReply(item, text: text) {
                        store.recordAppEvent(.agentFeedReplySucceeded)
                    } else if let failure = store.agentFeedFailedTerminalReplies[item.id] {
                        store.recordAppEvent(
                            .agentFeedReplyFailed,
                            count: failure.delivery == .notSent ? 0 : 1
                        )
                    }
                }
            },
            openDestination: { item in
                store.markAgentFeedItemInteracted(item)
                store.recordAppEvent(.agentFeedItemOpened, count: item.remoteSurfaceID == nil ? 0 : 1)
                Task {
                    showsNavigationFailure = !(await store.openAgentFeedDestination(
                        item,
                        openTab: item.remoteSurfaceID != nil
                    ))
                }
            },
            loadFullText: { item in
                store.markAgentFeedItemInteracted(item)
                return try await store.loadAgentFeedFullText(item)
            },
            setNeedsInput: { item, needsInput in
                store.setAgentFeedItemNeedsInput(item, needsInput)
            },
            refresh: {
                await store.refreshAgentFeed()
            },
            filterChanged: { filter in
                store.recordAppEvent(.agentFeedFilterChanged, count: filter == .needsInput ? 1 : 0)
            }
        )
    }

    private func updateFeedVisibility(_ active: Bool) {
        if active {
            guard !isFeedVisible else { return }
            isFeedVisible = true
            store.recordAppEvent(.agentFeedOpened, count: items.count)
        } else {
            guard isFeedVisible else { return }
            isFeedVisible = false
            store.recordAppEvent(.agentFeedClosed)
        }
    }
}
#endif
