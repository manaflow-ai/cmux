import AppKit
import Bonsplit
import CMUXWorkstream
import SwiftUI

/// Feed content surface. Isolated so the outer panel's `@State`
/// changes don't invalidate rows unnecessarily. Receives items as a
/// plain value so its body never touches the live store, the parent
/// owns the observation.
struct FeedListView: View {
    let filter: FeedPanelView.Filter
    let items: [WorkstreamItem]
    let hasMorePersistedItems: Bool
    let isLoadingOlderItems: Bool
    let onLoadOlderItems: () -> Void

    @State private var focusSnapshot = FeedFocusSnapshot()
    @State private var scrollRequest: FeedScrollRequest?
    @State private var scrollRequestSequence = 0
    @State private var stopDrafts: [UUID: FeedStopDraft] = [:]

    var body: some View {
        let snapshots = visibleSnapshots(items)
        let activityGroups = filter == .activity ? activitySnapshotGroups(snapshots) : nil
        let focusSnapshots = activityGroups?.ordered ?? snapshots
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
            .onChange(of: scrollRequest) { request in
                guard let request else { return }
                proxy.scrollTo(request.id, anchor: .top)
            }
            .background(
                FeedKeyboardFocusBridge(
                    onEscape: {
                        let window = activeFeedWindow()
                        if AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() != true {
                            window?.makeFirstResponder(nil)
                        }
                        syncFeedFocusSnapshot(window: window)
                    },
                    onMoveSelection: { delta in
                        moveSelection(in: focusSnapshots, delta: delta)
                    },
                    onActivateSelection: {
                        activateSelection(in: focusSnapshots, actions: rowActions)
                    },
                    onFocusFirstItemRequested: {
                        focusFirstVisibleItem(in: focusSnapshots, focusHost: false)
                    },
                    onFocusChanged: { focused in
                        let window = activeFeedWindow()
                        if !focused {
                            AppDelegate.shared?.syncKeyboardFocusAfterFirstResponderChange(in: window)
                        }
                        syncFeedFocusSnapshot(window: window)
                    },
                    onFocusSnapshotChanged: { snapshot in
                        focusSnapshot = snapshot
                    }
                )
                .frame(width: 1, height: 1)
            )
        }
    }

    @ViewBuilder
    private func contentBody(
        snapshots: [FeedItemSnapshot],
        activityGroups: ActivitySnapshotGroups?,
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
                groups: activityGroups ?? activitySnapshotGroups(snapshots),
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
                ForEach(Array(snapshots.enumerated()), id: \.element.id) { idx, snapshot in
                    rowSurface(
                        snapshot: snapshot,
                        actions: actions,
                        showsDivider: idx < snapshots.count - 1
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .feedZeroScrollContentMargins()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func activityScrollSurface(
        groups: ActivitySnapshotGroups,
        actions: FeedRowActions,
        showsLoadMore: Bool
    ) -> some View {
        List {
            ForEach(Array(groups.stable.enumerated()), id: \.element.id) { idx, snapshot in
                rowSurface(
                    snapshot: snapshot,
                    actions: actions,
                    showsDivider: idx < groups.stable.count - 1
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
            ForEach(Array(groups.history.enumerated()), id: \.element.id) { idx, snapshot in
                rowSurface(
                    snapshot: snapshot,
                    actions: actions,
                    showsDivider: idx < groups.history.count - 1
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

    private struct ActivitySnapshotGroups {
        let stable: [FeedItemSnapshot]
        let history: [FeedItemSnapshot]
        let ordered: [FeedItemSnapshot]
    }

    private func activitySnapshotGroups(_ snapshots: [FeedItemSnapshot]) -> ActivitySnapshotGroups {
        var stable: [FeedItemSnapshot] = []
        var history: [FeedItemSnapshot] = []
        stable.reserveCapacity(snapshots.count)
        history.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            if prefersStableSurface(snapshot) {
                stable.append(snapshot)
            } else {
                history.append(snapshot)
            }
        }
        return ActivitySnapshotGroups(stable: stable, history: history, ordered: stable + history)
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
                syncFeedFocusSnapshot()
            },
            onActivate: {
                selectRow(snapshot.id, focusFeed: true)
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

    /// Walks the full items list (not just the filtered visible set),
    /// ordered by createdAt, and records the most recent user-prompt
    /// text per workstreamId. Rows consult this dict to show a
    /// "You: …" echo line at the top of their card.
    private static func lastPromptByWorkstream(_ items: [WorkstreamItem]) -> [String: String] {
        var out: [String: String] = [:]
        for item in items {
            if case .userPrompt(let text) = item.payload, !text.isEmpty {
                out[item.workstreamId] = text
            }
        }
        return out
    }

    private func filtered(_ items: [WorkstreamItem]) -> [WorkstreamItem] {
        let base: [WorkstreamItem]
        switch filter {
        case .actionable:
            base = items.filter { $0.kind.isActionable }
        case .activity:
            // Actionable kinds + todos + stop. Tool use, user prompts,
            // assistant messages, session markers, and raw
            // notifications are intentionally excluded — they're too
            // noisy for a sidebar and already visible in the agent's
            // terminal or the cmux notification system. Stop events
            // render a "reply to Claude" textbox so the user can
            // nudge Claude without switching focus to the terminal.
            base = items.filter { item in
                item.kind.isActionable
                    || item.kind == .todos
                    || item.kind == .stop
            }
        }
        // Newest first. Status isn't a sort key — resolved items stay
        // in the chronological slot where they arrived so the user's
        // mental map of "this was the second request I got" doesn't
        // get shuffled when they answer it.
        return Array(base.reversed())
    }

    private func visibleSnapshots(_ items: [WorkstreamItem]) -> [FeedItemSnapshot] {
        let lastPromptByWorkstream = Self.lastPromptByWorkstream(items)
        return filtered(items).map { item in
            FeedItemSnapshot(
                item: item,
                userPromptEcho: lastPromptByWorkstream[item.workstreamId]
            )
        }
    }

    private func prefersStableSurface(_ snapshot: FeedItemSnapshot) -> Bool {
        snapshot.status.isPending || snapshot.kind == .stop
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
            FeedInlineNativeTextView.blurActiveEditor()
        }
        let optimisticSnapshot = FeedFocusSnapshot(selectedItemId: id, isKeyboardActive: true)
        focusSnapshot = optimisticSnapshot
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
            if focusHost {
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
        selectRow(snapshot.id, focusFeed: true)
        actions.jump(snapshot.workstreamId)
    }

    private func activeFeedWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func syncFeedFocusSnapshot(window: NSWindow? = nil) {
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
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(filter == .actionable
                 ? String(localized: "feed.empty.actionable.subtitle",
                          defaultValue: "Permission, plan, and question requests from AI agents will appear here.")
                 : String(localized: "feed.empty.activity.subtitle",
                          defaultValue: "Agent decisions and todo-list updates will appear here."))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FeedScrollRequest: Equatable {
    let id: UUID
    let sequence: Int
}

struct FeedStopDraft: Equatable {
    var reply = ""

    var isPristine: Bool {
        reply.isEmpty
    }
}

private struct FeedRowSurface: View {
    let snapshot: FeedItemSnapshot
    let actions: FeedRowActions
    let isSelected: Bool
    let isFocusActive: Bool
    let showsDivider: Bool
    @Binding var stopDraft: FeedStopDraft
    let onPressSelect: () -> Void
    let onControlFocus: () -> Void
    let onControlAction: () -> Void
    let onControlBlur: () -> Void
    let onActivate: () -> Void

    @State private var isHovered = false
    @State private var stopReplyFocusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            FeedItemRow(
                snapshot: snapshot,
                actions: actions,
                isSelected: isFocusActive,
                onPressSelect: onPressSelect,
                onControlFocus: onControlFocus,
                onControlAction: onControlAction,
                onControlBlur: onControlBlur,
                onActivate: onActivate,
                stopDraft: $stopDraft,
                stopDraftValue: stopDraft,
                stopFocusRequest: $stopReplyFocusRequest,
                stopFocusRequestValue: stopReplyFocusRequest
            )
            .equatable()
            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackgroundFill)
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackgroundFill: Color {
        if isSelected {
            guard isFocusActive else {
                return Color.primary.opacity(0.07)
            }
            if snapshot.status.isPending {
                return tint.opacity(0.14)
            }
            return Color.primary.opacity(0.075)
        }
        if isHovered {
            if snapshot.status.isPending {
                return tint.opacity(0.10)
            }
            return Color.primary.opacity(0.055)
        }
        return .clear
    }

    private var tint: Color {
        switch snapshot.kind {
        case .permissionRequest: return .orange
        case .exitPlan: return .purple
        case .question: return .blue
        default: return snapshot.status.isPending ? .orange : .secondary.opacity(0.8)
        }
    }
}

private extension View {
    @ViewBuilder
    func feedZeroScrollContentMargins() -> some View {
        if #available(macOS 14.0, *) {
            contentMargins(.all, 0, for: .scrollContent)
        } else {
            self
        }
    }
}

// MARK: - Kind → SF Symbol

