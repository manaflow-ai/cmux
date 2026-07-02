import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxAppKitSupportUI
import CmuxFeedUI
import CmuxSidebar
import CmuxWindowing
import SwiftUI
#if DEBUG
private func feedDebugResponderSummary(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}
#endif

/// Right-sidebar Feed view. Matches the Sessions page visual language:
/// compact rows with SF Symbol + 13pt title + secondary metadata,
/// full-width hover backgrounds, and control-bar pill buttons styled
/// like `GroupingButton` in `SessionIndexView`.
///
/// Pending items float above resolved; telemetry is hidden unless the
/// user flips the Actionable / All filter. Rows receive immutable
/// snapshots + closure action bundles only (snapshot-boundary rule).
struct FeedPanelView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case actionable
        case activity
        var id: String { rawValue }
        var label: String {
            switch self {
            case .actionable:
                return String(localized: "feed.filter.actionable", defaultValue: "Actionable")
            case .activity:
                return String(localized: "feed.filter.activity", defaultValue: "All Activity")
            }
        }
        var symbolName: String {
            switch self {
            case .actionable: return "exclamationmark.circle"
            case .activity: return "checklist"
            }
        }
    }

    @State private var filter: Filter = .actionable
    @State private var viewModel = FeedPanelViewModel()

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            FeedListView(
                filter: filter,
                items: viewModel.items,
                hasMorePersistedItems: viewModel.hasMorePersistedItems,
                isLoadingOlderItems: viewModel.isLoadingOlderItems,
                onLoadOlderItems: viewModel.loadOlderItems
            )
        }
    }

    private var controlBar: some View {
        Group {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 6) {
                    controlBarContent
                }
            } else {
                controlBarContent
            }
            #else
            controlBarContent
            #endif
        }
        .rightSidebarChromeBar()
        .rightSidebarChromeBottomBorder()
        .reportRightSidebarChromeGeometryForBonsplitUITest(role: .secondaryBar, isVisible: true, titlebarHeight: RightSidebarChromeMetrics.secondaryBarHeight)
    }

    private var controlBarContent: some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases) { f in
                FeedSecondaryFilterButton(
                    filter: f,
                    isSelected: filter == f
                ) {
                    filter = f
                }
            }
            Spacer(minLength: 4)
        }
    }
}

private struct FeedSecondaryFilterButton: View {
    let filter: FeedPanelView.Filter
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: filter.symbolName)
                    .symbolRenderingMode(.monochrome)
                    .font(
                        .system(
                            size: RightSidebarChromeControlStyle.secondaryIconSize,
                            weight: RightSidebarChromeControlStyle.iconWeight
                        )
                    )
                Text(filter.label)
                    .font(
                        .system(
                            size: RightSidebarChromeControlStyle.labelSize,
                            weight: RightSidebarChromeControlStyle.labelWeight
                        )
                    )
            }
            .rightSidebarChromePill(
                isSelected: isSelected,
                isHovered: isHovered,
                geometryKeyPrefix: "rightSidebarSecondaryControl_feed_\(filter.rawValue)"
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(filter.label)
    }
}

/// Feed content surface. Isolated so the outer panel's `@State`
/// changes don't invalidate rows unnecessarily. Receives items as a
/// plain value so its body never touches the live store, the parent
/// owns the observation.
private struct FeedListView: View {
    let filter: FeedPanelView.Filter
    let items: [WorkstreamItem]
    let hasMorePersistedItems: Bool
    let isLoadingOlderItems: Bool
    let onLoadOlderItems: () -> Void

    @Environment(\.appEnvironment) private var appEnvironment
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
        let lastPromptByWorkstream = FeedItemSnapshot.lastPromptByWorkstream(items)
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
                _ = appEnvironment?.mainWindowRouter.focusRightSidebarInActiveWindow(
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

private struct FeedKeyboardFocusBridge: NSViewRepresentable {
    let onEscape: () -> Void
    let onMoveSelection: (Int) -> Void
    let onActivateSelection: () -> Void
    let onFocusFirstItemRequested: () -> Void
    let onFocusChanged: (Bool) -> Void
    let onFocusSnapshotChanged: (FeedFocusSnapshot) -> Void

    func makeNSView(context: Context) -> FeedKeyboardFocusView {
        let view = FeedKeyboardFocusView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.onEscape = onEscape
        view.onMoveSelection = onMoveSelection
        view.onActivateSelection = onActivateSelection
        view.onFocusFirstItemRequested = onFocusFirstItemRequested
        view.onFocusChanged = onFocusChanged
        view.onFocusSnapshotChanged = onFocusSnapshotChanged
        return view
    }

    func updateNSView(_ nsView: FeedKeyboardFocusView, context: Context) {
        nsView.onEscape = onEscape
        nsView.onMoveSelection = onMoveSelection
        nsView.onActivateSelection = onActivateSelection
        nsView.onFocusFirstItemRequested = onFocusFirstItemRequested
        nsView.onFocusChanged = onFocusChanged
        nsView.onFocusSnapshotChanged = onFocusSnapshotChanged
        nsView.registerWithKeyboardFocusCoordinatorIfNeeded()
    }
}

final class FeedKeyboardFocusView: NSView, FeedFocusHosting {
    var onEscape: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onFocusFirstItemRequested: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onFocusSnapshotChanged: ((FeedFocusSnapshot) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFeedHost(self)
#if DEBUG
        dlog("feed.focus.host attach window=\(ObjectIdentifier(window))")
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFeedHost(self)
    }

    override func layout() {
        super.layout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
#if DEBUG
            dlog(
                "feed.focus.host escape window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
                "fr=\(feedDebugResponderSummary(window?.firstResponder))"
            )
#endif
            onEscape?()
            return true
        }
        if let delta = event.rightSidebarMoveDelta {
            onMoveSelection?(delta)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        let chars = event.charactersIgnoringModifiers ?? ""
        dlog(
            "feed.focus.host keyDown key=\(event.keyCode) chars=\(chars) " +
            "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }

        if let delta = event.rightSidebarMoveDelta {
            onMoveSelection?(delta)
            return
        }

        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShortcutModifier = !normalizedFlags.intersection([.command, .control, .option]).isEmpty
        guard !hasShortcutModifier else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 76:
            onActivateSelection?()
            return
        case 53:
            onEscape?()
            return
        default:
            break
        }

        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusChanged?(true)
        }
#if DEBUG
        dlog(
            "feed.focus.host become result=\(result ? 1 : 0) " +
            "window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
            "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            onFocusChanged?(false)
        }
#if DEBUG
        dlog(
            "feed.focus.host resign result=\(result ? 1 : 0) " +
            "window=\(window.map { String(describing: ObjectIdentifier($0)) } ?? "nil") " +
            "fr=\(feedDebugResponderSummary(window?.firstResponder))"
        )
#endif
        return result
    }

    func focusFirstItemFromCoordinator() {
        onFocusFirstItemRequested?()
    }

    func focusHostFromCoordinator() -> Bool {
        guard let window else { return false }
#if DEBUG
        let before = feedDebugResponderSummary(window.firstResponder)
#endif
        let result = window.makeFirstResponder(self)
#if DEBUG
        dlog(
            "feed.focus.host request result=\(result ? 1 : 0) " +
            "window=\(ObjectIdentifier(window)) before=\(before) " +
            "after=\(feedDebugResponderSummary(window.firstResponder))"
        )
#endif
        return result
    }

    func applyFocusSnapshotFromController(_ snapshot: FeedFocusSnapshot) {
        onFocusSnapshotChanged?(snapshot)
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        responder === self || responder is FeedKeyboardFocusResponder
    }
}

// MARK: - Row snapshot + actions (respects snapshot-boundary rule)

/// Closure bundle; binds to `FeedCoordinator` by default.
extension FeedRowActions {
    static func bound() -> FeedRowActions {
        FeedRowActions(
            approvePermission: { itemId, mode in
                Task { @MainActor in
                    FeedCoordinator.shared.deliverReply(
                        requestId: Self.requestId(for: itemId) ?? itemId.uuidString,
                        decision: .permission(mode)
                    )
                }
            },
            replyQuestion: { itemId, selections in
                Task { @MainActor in
                    FeedCoordinator.shared.deliverReply(
                        requestId: Self.requestId(for: itemId) ?? itemId.uuidString,
                        decision: .question(selections: selections)
                    )
                }
            },
            approveExitPlan: { itemId, mode, feedback in
                Task { @MainActor in
                    FeedCoordinator.shared.deliverReply(
                        requestId: Self.requestId(for: itemId) ?? itemId.uuidString,
                        decision: .exitPlan(mode, feedback: feedback)
                    )
                }
            },
            jump: { workstreamId in
                Task { @MainActor in
                    _ = FeedCoordinator.shared.socketRouter.focusIfPossible(workstreamId: workstreamId)
                }
            },
            sendText: { workstreamId, text in
                Task { @MainActor in
                    FeedCoordinator.shared.socketRouter.sendTextToWorkstream(
                        workstreamId: workstreamId,
                        text: text
                    )
                }
            }
        )
    }

    @MainActor
    private static func requestId(for itemId: UUID) -> String? {
        guard let store = FeedCoordinator.shared.store else { return nil }
        return store.items.first(where: { $0.id == itemId }).flatMap { item in
            switch item.payload {
            case .permissionRequest(let rid, _, _, _): return rid
            case .exitPlan(let rid, _, _): return rid
            case .question(let rid, _): return rid
            default: return nil
            }
        }
    }
}

// MARK: - Row (matches SessionIndexView row aesthetic)

struct FeedItemRow: View, Equatable {
    let snapshot: FeedItemSnapshot
    let actions: FeedRowActions
    let isSelected: Bool
    let onPressSelect: () -> Void
    let onControlFocus: () -> Void
    let onControlAction: () -> Void
    let onControlBlur: () -> Void
    let onActivate: () -> Void
    @Binding var stopDraft: FeedStopDraft
    let stopDraftValue: FeedStopDraft
    @Binding var stopFocusRequest: Int
    let stopFocusRequestValue: Int

    @State private var didHandlePressSelection = false

    static func == (lhs: FeedItemRow, rhs: FeedItemRow) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.isSelected == rhs.isSelected
            && lhs.stopDraftValue == rhs.stopDraftValue
            && lhs.stopFocusRequestValue == rhs.stopFocusRequestValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            chipHeader
            if let context = displayContext {
                FeedContextBlock(context: context, source: snapshot.source)
            } else if let echo = promptEcho, !echo.isEmpty {
                Text(echo)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            actionArea
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isResolvedOrExpired ? 0.6 : 1.0)
        .contentShape(Rectangle())
        .help(helpText)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !didHandlePressSelection {
                        didHandlePressSelection = true
                        onPressSelect()
                    }
                }
                .onEnded { _ in
                    didHandlePressSelection = false
                }
        )
        .onTapGesture(count: 2, perform: onActivate)
    }

    private var promptEcho: String? {
        // Prefer the real user prompt attached by the list view (walks
        // the same workstream for the most recent .userPrompt
        // telemetry). Synthetic permission labels are intentionally
        // avoided here because the Feed should show real context only.
        if let echo = snapshot.userPromptEcho,
           !echo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return String(localized: "feed.promptEcho", defaultValue: "You: \(echo)")
        }
        return nil
    }

    private var displayContext: WorkstreamContext? {
        let fallback = WorkstreamContext(lastUserMessage: snapshot.userPromptEcho)
        let context = snapshot.context?.mergingMissing(from: fallback) ?? fallback
        return context.isEmpty ? nil : context
    }

    private var isResolvedOrExpired: Bool {
        switch snapshot.status {
        case .pending: return false
        case .telemetry: return false
        case .resolved, .expired: return true
        }
    }

    /// Compact header: kind icon + project/path title on the left,
    /// agent and age on the right.
    private var chipHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: snapshot.kind.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(kindTint)
                .frame(width: 14, height: 14)
            Text(headerTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                chip(
                    text: snapshot.source.rawValue.capitalized,
                    fg: sourceChipForeground,
                    bg: sourceChipBackground
                )
                chip(
                    text: relativeTimeChip(snapshot.createdAt),
                    fg: .secondary,
                    bg: Color.primary.opacity(0.10),
                    mono: true
                )
            }
        }
    }

    private var headerTitle: String {
        // Prefer the user prompt as the card title, but keep question
        // headers before it so short labels like "Demo style" survive
        // middle truncation.
        let promptLine = (displayContext?.lastUserMessage ?? snapshot.userPromptEcho)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let questionHeader = questionHeaderForTitle
        if !promptLine.isEmpty {
            let detail = [questionHeader, promptLine].compactMap { $0 }.joined(separator: " · ")
            if let cwd = snapshot.cwd, !cwd.isEmpty {
                return "\(cwdBasename(cwd)) · \(detail)"
            }
            return detail
        }
        if let questionHeader {
            if let cwd = snapshot.cwd, !cwd.isEmpty {
                return "\(cwdBasename(cwd)) · \(questionHeader)"
            }
            return questionHeader
        }
        if let title = snapshot.title, !title.isEmpty {
            if let cwd = snapshot.cwd, !cwd.isEmpty {
                return "\(cwdBasename(cwd)) · \(title)"
            }
            return title
        }
        if let cwd = snapshot.cwd, !cwd.isEmpty {
            return "\(cwdBasename(cwd)) · \(kindLabel.capitalized)"
        }
        return kindLabel.capitalized
    }

    private var questionHeaderForTitle: String? {
        guard case .question(_, let questions) = snapshot.payload else { return nil }
        return questions
            .compactMap { $0.header?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// Last path component only — `fun` instead of `~/fun` or the full
    /// absolute path. Matches the Vibe-Island mockup's compact header.
    private func cwdBasename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func chip(text: String, fg: Color, bg: Color, mono: Bool = false) -> some View {
        Text(text)
            .font(mono
                  ? .system(size: 10, weight: .medium).monospacedDigit()
                  : .system(size: 10, weight: .medium))
            .foregroundColor(fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(bg)
            )
    }

    private var sourceChipForeground: Color {
        switch snapshot.source {
        case .claude: return Color(red: 0.92, green: 0.54, blue: 0.29)
        case .codex: return .green
        case .opencode: return .blue
        case .hermesAgent: return .teal
        case .cursor: return .purple
        default: return .secondary
        }
    }
    private var sourceChipBackground: Color {
        return sourceChipForeground.opacity(0.18)
    }

    private func relativeTimeChip(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "<1m" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86_400))d"
    }

    private var kindLabel: String {
        switch snapshot.kind {
        case .permissionRequest:
            return String(localized: "feed.kind.permission", defaultValue: "PERMISSION")
        case .exitPlan:
            return String(localized: "feed.kind.plan", defaultValue: "PLAN")
        case .question:
            return String(localized: "feed.kind.question.upper", defaultValue: "QUESTION")
        case .toolUse:
            return String(localized: "feed.kind.toolUse", defaultValue: "TOOL USE")
        case .toolResult:
            return String(localized: "feed.kind.toolResult", defaultValue: "TOOL RESULT")
        case .userPrompt:
            return String(localized: "feed.kind.prompt", defaultValue: "PROMPT")
        case .assistantMessage:
            return String(localized: "feed.kind.message", defaultValue: "MESSAGE")
        case .sessionStart:
            return String(localized: "feed.kind.sessionStart.upper", defaultValue: "SESSION START")
        case .sessionEnd:
            return String(localized: "feed.kind.sessionEnd.upper", defaultValue: "SESSION END")
        case .stop:
            return String(localized: "feed.kind.stop", defaultValue: "STOP")
        case .todos:
            return String(localized: "feed.kind.todos", defaultValue: "TODOS")
        }
    }

    private var kindTint: Color {
        switch snapshot.kind {
        case .permissionRequest: return .orange
        case .exitPlan: return .purple
        case .question: return .blue
        default: return snapshot.status.isPending ? .orange : .secondary.opacity(0.8)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch snapshot.payload {
        case .permissionRequest(_, let toolName, let toolInputJSON, _):
            PermissionActionArea(
                toolName: toolName,
                toolInputJSON: toolInputJSON,
                source: snapshot.source,
                status: snapshot.status,
                onActionRow: onControlAction,
                onApprove: { mode in
                    actions.approvePermission(snapshot.id, mode)
                }
            )
        case .exitPlan(_, let plan, _):
            ExitPlanActionArea(
                plan: plan,
                source: snapshot.source,
                status: snapshot.status,
                isRowSelected: isSelected,
                onFocusRow: onControlFocus,
                onActionRow: onControlAction,
                onBlurRow: onControlBlur,
                onApprove: { mode, feedback in
                    actions.approveExitPlan(snapshot.id, mode, feedback)
                }
            )
        case .question(_, let questions):
            QuestionActionArea(
                questions: questions,
                source: snapshot.source,
                status: snapshot.status,
                isRowSelected: isSelected,
                onFocusRow: onControlFocus,
                onActionRow: onControlAction,
                onBlurRow: onControlBlur,
                context: displayContext,
                onReply: { selections in
                    actions.replyQuestion(snapshot.id, selections)
                },
                focusFeedHost: { window in
                    AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                        mode: .feed,
                        focusFirstItem: false,
                        preferredWindow: window
                    ) == true
                },
                isFeedFocusHostResponder: { $0 is FeedKeyboardFocusView }
            )
        case .stop:
            StopActionArea(
                draft: $stopDraft,
                focusRequest: $stopFocusRequest,
                labelText: String(localized: "feed.stop.label", defaultValue: "Claude finished — reply to continue"),
                placeholderText: String(localized: "feed.stop.placeholder", defaultValue: "Reply to Claude…"),
                sendLabel: String(localized: "feed.stop.send", defaultValue: "Send to Claude"),
                onFocusRow: onControlFocus,
                onActionRow: onControlAction,
                onBlurRow: onControlBlur,
                onSend: { text in actions.sendText(snapshot.workstreamId, text) },
                focusFeedHost: { window in
                    AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                        mode: .feed,
                        focusFirstItem: false,
                        preferredWindow: window
                    ) == true
                },
                isFeedFocusHostResponder: { $0 is FeedKeyboardFocusView }
            )
        default:
            TelemetryActionArea(snapshot: snapshot)
        }
    }

    private var primaryTitle: String {
        switch snapshot.payload {
        case .permissionRequest(_, let toolName, _, _):
            return "\(snapshot.source.rawValue.capitalized) · \(toolName)"
        case .exitPlan:
            return "\(snapshot.source.rawValue.capitalized) · \(String(localized: "feed.kind.exitPlan", defaultValue: "Exit plan"))"
        case .question:
            return "\(snapshot.source.rawValue.capitalized) · \(String(localized: "feed.kind.question", defaultValue: "Question"))"
        default:
            if let title = snapshot.title, !title.isEmpty {
                return "\(snapshot.source.rawValue.capitalized) · \(title)"
            }
            return snapshot.source.rawValue.capitalized
        }
    }

    private var helpText: String {
        var lines: [String] = [primaryTitle]
        if let cwd = snapshot.cwd { lines.append(cwd) }
        lines.append(absoluteTime(snapshot.createdAt))
        return lines.joined(separator: "\n")
    }

    private func resolvedBadgeLabel(_ decision: WorkstreamDecision) -> String {
        let submitted = String(localized: "feed.badge.submitted", defaultValue: "Submitted")
        switch decision {
        case .permission(let m):
            return "\(submitted) · \(m.displayLabel)"
        case .exitPlan(let m, let feedback):
            if let feedback, !feedback.isEmpty {
                return "\(submitted) · " + String(localized: "feed.badge.refined", defaultValue: "refined")
            }
            return "\(submitted) · \(m.displayLabel)"
        case .question:
            return submitted
        }
    }

    private func statusTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }

    private func relativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteTime(_ date: Date) -> String {
        Self.absoluteFormatter.string(from: date)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Per-kind action areas

// The inline feed editor (`FeedInlineNativeTextView`/`FeedInlineTextField`) now
// lives in `CmuxFeedUI`. The right-sidebar focus router
// (`RightSidebarFocusHostRouter`) recognizes a focused feed editor via the
// `CmuxSidebar` `FeedKeyboardFocusResponder` marker, so the composition root
// declares that conformance here instead of having the UI package depend on the
// sidebar module.
extension FeedInlineNativeTextView: @retroactive FeedKeyboardFocusResponder {}
