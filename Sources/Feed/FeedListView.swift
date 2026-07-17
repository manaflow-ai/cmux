import AppKit
import Bonsplit
import CMUXAgentLaunch
import Foundation
import SwiftUI

struct FeedListView: View {
    let filter: FeedPanelView.Filter
    let presentation: FeedPresentationSnapshot
    let placement: FeedPlacement
    let focusScopeID: UUID
    let onFocusHostChange: (FeedKeyboardFocusView?) -> Void
    let hasMorePersistedItems: Bool
    let isLoadingOlderItems: Bool
    let onLoadOlderItems: () -> Void

    @State private var focusSnapshot = FeedFocusSnapshot()
    @State private var scrollRequest: FeedScrollRequest?
    @State private var scrollRequestSequence = 0
    @State private var stopDrafts: [UUID: FeedStopDraft] = [:]
    @State private var focusHostRequest = 0
    @State private var focusHostReference = FeedFocusHostReference()

    var body: some View {
        let activityGroups = filter == .activity ? presentation.activity : nil
        let snapshots = activityGroups?.ordered ?? presentation.actionable
        let rowActions = FeedRowActions.bound()
        ScrollViewReader { proxy in
            Group {
                if snapshots.isEmpty && !shouldShowActivityHistoryLoader {
                    emptyState
                } else {
                    contentBody(
                        snapshots: snapshots,
                        activityGroups: activityGroups,
                        actions: rowActions
                    )
                }
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                proxy.scrollTo(request.id, anchor: .top)
            }
            .background(
                FeedKeyboardFocusBridge(
                    placement: placement,
                    focusScopeID: focusScopeID,
                    focusRequest: focusHostRequest,
                    onHostChange: { host in
                        focusHostReference.host = host
                        onFocusHostChange(host)
                    },
                    onEscape: {
                        let window = activeFeedWindow()
                        if placement.usesRightSidebarFocusCoordinator,
                           AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
                            syncFeedFocusSnapshot(window: window)
                            return
                        }
                        if window?.firstResponder is FeedKeyboardFocusResponder
                            || window?.firstResponder is FeedKeyboardFocusView {
                            window?.makeFirstResponder(nil)
                        }
                        focusSnapshot.isKeyboardActive = false
                    },
                    onMoveSelection: { delta in
                        moveSelection(in: snapshots, delta: delta)
                    },
                    onActivateSelection: {
                        activateSelection(in: snapshots, actions: rowActions)
                    },
                    onFocusFirstItemRequested: {
                        focusFirstVisibleItem(in: snapshots, focusHost: false)
                    },
                    onFocusChanged: { focused in
                        let window = activeFeedWindow()
                        if !placement.usesRightSidebarFocusCoordinator {
                            focusSnapshot.isKeyboardActive = focused
                        } else if !focused {
                            AppDelegate.shared?.syncKeyboardFocusAfterFirstResponderChange(in: window)
                            syncFeedFocusSnapshot(window: window)
                        }
                    },
                    onFocusSnapshotChanged: { snapshot in
                        if placement.usesRightSidebarFocusCoordinator {
                            focusSnapshot = snapshot
                        }
                    }
                )
                .frame(width: 1, height: 1)
            )
        }
    }

    @ViewBuilder
    private func contentBody(
        snapshots: [FeedItemSnapshot],
        activityGroups: FeedActivitySnapshotGroups?,
        actions: FeedRowActions
    ) -> some View {
        switch filter {
        case .actionable:
            stableScrollSurface(
                snapshots: snapshots,
                actions: actions
            )
        case .activity:
            activityScrollSurface(
                groups: activityGroups ?? FeedActivitySnapshotGroups(stable: [], history: []),
                actions: actions,
                showsLoadMore: hasMorePersistedItems
            )
        }
    }

    private func stableScrollSurface(
        snapshots: [FeedItemSnapshot],
        actions: FeedRowActions
    ) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(snapshots, id: \.id) { snapshot in
                    rowSurface(
                        snapshot: snapshot,
                        actions: actions,
                        showsDivider: snapshot.id != snapshots.last?.id
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .feedZeroScrollContentMargins()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func activityScrollSurface(
        groups: FeedActivitySnapshotGroups,
        actions: FeedRowActions,
        showsLoadMore: Bool
    ) -> some View {
        List {
            ForEach(groups.stable, id: \.id) { snapshot in
                rowSurface(
                    snapshot: snapshot,
                    actions: actions,
                    showsDivider: snapshot.id != groups.stable.last?.id
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if !groups.stable.isEmpty && (!groups.history.isEmpty || showsLoadMore) {
                rowSeparator
                    .id("feed.activity.separator")
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(groups.history, id: \.id) { snapshot in
                rowSurface(
                    snapshot: snapshot,
                    actions: actions,
                    showsDivider: snapshot.id != groups.history.last?.id
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if showsLoadMore {
                FeedHistoryLoadMoreRow(
                    isLoading: isLoadingOlderItems,
                    action: onLoadOlderItems
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .feedZeroScrollContentMargins()
        .environment(\.defaultMinListRowHeight, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowSurface(
        snapshot: FeedItemSnapshot,
        actions: FeedRowActions,
        showsDivider: Bool
    ) -> some View {
        FeedRowSurface(
            snapshot: snapshot,
            actions: actions,
            isSelected: focusSnapshot.selectedItemId == snapshot.id,
            isFocusActive: focusSnapshot.isKeyboardActive && focusSnapshot.selectedItemId == snapshot.id,
            showsDivider: showsDivider,
            stopDraft: stopDraftBinding(for: snapshot.id),
            placement: placement,
            focusScopeID: focusScopeID,
            onPressSelect: {
                selectRow(snapshot.id, focusFeed: false)
            },
            onControlFocus: {
                selectRow(snapshot.id, focusFeed: false)
            },
            onControlAction: {
                selectRow(snapshot.id, focusFeed: true)
            },
            onControlBlur: {
                if !placement.usesRightSidebarFocusCoordinator {
                    focusSnapshot.isKeyboardActive = false
                } else {
                    syncFeedFocusSnapshot()
                }
            },
            onActivate: {
                selectRow(snapshot.id, focusFeed: false)
                actions.jump(snapshot.workstreamId)
            }
        )
        .id(snapshot.id)
    }

    private func stopDraftBinding(for id: UUID) -> Binding<FeedStopDraft> {
        Binding(
            get: { stopDrafts[id] ?? FeedStopDraft() },
            set: { draft in
                if draft.isPristine {
                    stopDrafts.removeValue(forKey: id)
                } else {
                    stopDrafts[id] = draft
                }
            }
        )
    }

    private var shouldShowActivityHistoryLoader: Bool {
        filter == .activity && hasMorePersistedItems
    }

    private func selectRow(_ id: UUID, focusFeed: Bool) {
        let selectionChanged = focusSnapshot.selectedItemId != id
        let window = activeFeedWindow()
#if DEBUG
        dlog(
            "feed.focus.select begin id=\(id.uuidString.prefix(5)) " +
            "focusFeed=\(focusFeed ? 1 : 0) selectionChanged=\(selectionChanged ? 1 : 0) " +
            "frBefore=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        if focusFeed {
            FeedInlineNativeTextView.blurActiveEditor(in: window)
        }
        let ownsKeyboardFocus = focusHostReference.host.flatMap { host in
            host.window?.firstResponder.map(host.ownsKeyboardFocus(_:))
        } ?? false
        let optimisticSnapshot = FeedFocusSnapshot(
            selectedItemId: id,
            isKeyboardActive: focusFeed || ownsKeyboardFocus
        )
        focusSnapshot = optimisticSnapshot
        if !placement.usesRightSidebarFocusCoordinator {
            if focusFeed {
                focusHostRequest &+= 1
            }
            return
        }
        if let controller = AppDelegate.shared?.keyboardFocusCoordinator(for: window) {
            _ = controller.selectFeedItem(id, focusFeed: focusFeed)
            focusSnapshot = controller.feedFocusSnapshot()
        } else {
            focusSnapshot = optimisticSnapshot
        }
#if DEBUG
        let afterWindow = activeFeedWindow()
        dlog(
            "feed.focus.select end id=\(id.uuidString.prefix(5)) " +
            "focusFeed=\(focusFeed ? 1 : 0) selected=\(focusSnapshot.selectedItemId == id ? 1 : 0) " +
            "active=\(focusSnapshot.isKeyboardActive ? 1 : 0) " +
            "frAfter=\(feedDebugResponderSummary(afterWindow?.firstResponder))"
        )
#endif
    }

    private func focusFirstVisibleItem(in snapshots: [FeedItemSnapshot], focusHost: Bool = true) {
        guard let targetId = preferredFocusItemId(in: snapshots) else {
            let window = activeFeedWindow()
            if !placement.usesRightSidebarFocusCoordinator {
                if focusHost {
                    focusHostRequest &+= 1
                }
                focusSnapshot.isKeyboardActive = focusHost
            } else if focusHost {
                _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                    mode: .feed,
                    focusFirstItem: false,
                    preferredWindow: window
                )
            } else {
                AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(
                    mode: .feed,
                    in: window
                )
            }
            syncFeedFocusSnapshot(window: window)
            return
        }
        selectRow(targetId, focusFeed: focusHost)
        scrollRequestSequence &+= 1
        scrollRequest = FeedScrollRequest(id: targetId, sequence: scrollRequestSequence)
    }

    private func preferredFocusItemId(in snapshots: [FeedItemSnapshot]) -> UUID? {
        let ids = snapshots.map(\.id)
        if !placement.usesRightSidebarFocusCoordinator {
            if let selectedItemId = focusSnapshot.selectedItemId,
               ids.contains(selectedItemId) {
                return selectedItemId
            }
            return ids.first
        }
        let window = activeFeedWindow()
        if let controllerSelectedId = AppDelegate.shared?
            .keyboardFocusCoordinator(for: window)?
            .feedFocusSnapshot()
            .selectedItemId,
            ids.contains(controllerSelectedId)
        {
            return controllerSelectedId
        }
        if let selectedItemId = focusSnapshot.selectedItemId,
           ids.contains(selectedItemId) {
            return selectedItemId
        }
        return ids.first
    }

    private func moveSelection(in snapshots: [FeedItemSnapshot], delta: Int) {
        guard !snapshots.isEmpty else { return }
        let ids = snapshots.map(\.id)
        let targetIndex: Int
        if let selectedItemId = focusSnapshot.selectedItemId,
           let currentIndex = ids.firstIndex(of: selectedItemId) {
            targetIndex = min(max(currentIndex + delta, 0), ids.count - 1)
        } else {
            targetIndex = delta >= 0 ? 0 : ids.count - 1
        }
        let targetId = ids[targetIndex]
        if !placement.usesRightSidebarFocusCoordinator {
            focusSnapshot = FeedFocusSnapshot(selectedItemId: targetId, isKeyboardActive: true)
            scrollRequestSequence &+= 1
            scrollRequest = FeedScrollRequest(id: targetId, sequence: scrollRequestSequence)
            return
        }
        let window = activeFeedWindow()
        if let controller = AppDelegate.shared?.keyboardFocusCoordinator(for: window) {
            _ = controller.selectFeedItem(targetId, focusFeed: false)
            focusSnapshot = controller.feedFocusSnapshot()
        } else {
            focusSnapshot = FeedFocusSnapshot(selectedItemId: targetId, isKeyboardActive: true)
        }
        scrollRequestSequence &+= 1
        scrollRequest = FeedScrollRequest(id: targetId, sequence: scrollRequestSequence)
#if DEBUG
        dlog(
            "feed.focus.move delta=\(delta) " +
            "target=\(targetId.uuidString.prefix(5)) count=\(ids.count)"
        )
#endif
    }

    private func activateSelection(
        in snapshots: [FeedItemSnapshot],
        actions: FeedRowActions
    ) {
        guard !snapshots.isEmpty else { return }
        let snapshot: FeedItemSnapshot
        if let selectedItemId = focusSnapshot.selectedItemId,
           let matched = snapshots.first(where: { $0.id == selectedItemId }) {
            snapshot = matched
        } else {
            snapshot = snapshots[0]
        }
        selectRow(snapshot.id, focusFeed: false)
        actions.jump(snapshot.workstreamId)
    }

    private func activeFeedWindow() -> NSWindow? {
        focusHostReference.host?.window
    }

    private func syncFeedFocusSnapshot(window: NSWindow? = nil) {
        guard placement.usesRightSidebarFocusCoordinator else { return }
        let targetWindow = window ?? activeFeedWindow()
        guard let controller = AppDelegate.shared?.keyboardFocusCoordinator(for: targetWindow) else {
            return
        }
        focusSnapshot = controller.feedFocusSnapshot()
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(maxWidth: .infinity)
            .frame(height: 1)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(filter == .actionable
                 ? String(localized: "feed.empty.actionable.title",
                          defaultValue: "No pending decisions")
                 : String(localized: "feed.empty.activity.title",
                          defaultValue: "No activity yet"))
                .cmuxFont(size: 12)
                .foregroundColor(.secondary)
            Text(filter == .actionable
                 ? String(localized: "feed.empty.actionable.subtitle",
                          defaultValue: "Permission, plan, and question requests from AI agents will appear here.")
                 : String(localized: "feed.empty.activity.subtitle",
                          defaultValue: "Agent decisions and todo-list updates will appear here."))
                .cmuxFont(size: 11)
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
