import AppKit
import Bonsplit
import CMUXWorkstream
import SwiftUI

#if DEBUG
private func feedDebugResponderSummary(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}
#endif

private extension WorkstreamPermissionMode {
    var displayLabel: String {
        switch self {
        case .once:
            return String(localized: "feed.permission.mode.once", defaultValue: "once")
        case .always:
            return String(localized: "feed.permission.mode.always", defaultValue: "always")
        case .all:
            return String(localized: "feed.permission.mode.all", defaultValue: "all tools")
        case .bypass:
            return String(localized: "feed.permission.mode.bypass", defaultValue: "bypass")
        case .deny:
            return String(localized: "feed.permission.mode.deny", defaultValue: "denied")
        }
    }
}

private extension WorkstreamExitPlanMode {
    var displayLabel: String {
        switch self {
        case .ultraplan:
            return String(localized: "feed.exitplan.mode.ultraplan", defaultValue: "ultraplan")
        case .bypassPermissions:
            return String(localized: "feed.exitplan.mode.bypass", defaultValue: "bypass")
        case .autoAccept:
            return String(localized: "feed.exitplan.mode.autoAccept", defaultValue: "auto")
        case .manual:
            return String(localized: "feed.exitplan.mode.manual", defaultValue: "manual")
        case .deny:
            return String(localized: "feed.exitplan.mode.deny", defaultValue: "denied")
        }
    }
}

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
                return String(localized: "feed.filter.activity", defaultValue: "Activity")
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
    @StateObject private var viewModel = FeedPanelViewModel()

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
            ForEach([Filter.actionable]) { f in
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
                    .font(.system(size: 10, weight: .medium))
                Text(filter.label)
                    .font(.system(size: 11, weight: .medium))
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

    @State private var focusSnapshot = FeedFocusSnapshot()
    @State private var scrollRequest: FeedScrollRequest?
    @State private var scrollRequestSequence = 0

    var body: some View {
        let snapshots = visibleSnapshots(items)
        let rowActions = FeedRowActions.bound()
        ScrollViewReader { proxy in
            Group {
                if snapshots.isEmpty && !shouldShowActivityHistoryLoader {
                    emptyState
                } else {
                    contentBody(
                        snapshots: snapshots,
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
        actions: FeedRowActions
    ) -> some View {
        switch filter {
        case .actionable:
            stableScrollSurface(
                snapshots: snapshots,
                actions: actions
            )
        case .activity:
            let stable = snapshots.filter(prefersStableSurface)
            let history = snapshots.filter { !prefersStableSurface($0) }
            if history.isEmpty && !hasMorePersistedItems {
                stableScrollSurface(
                    snapshots: stable,
                    actions: actions
                )
            } else {
                VStack(spacing: 0) {
                    if !stable.isEmpty {
                        stableRows(
                            snapshots: stable,
                            actions: actions
                        )
                        rowSeparator
                    }
                    historyList(
                        snapshots: history,
                        actions: actions,
                        showsLoadMore: hasMorePersistedItems
                    )
                }
            }
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

    private func stableRows(
        snapshots: [FeedItemSnapshot],
        actions: FeedRowActions
    ) -> some View {
        VStack(spacing: 0) {
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

    private func historyList(
        snapshots: [FeedItemSnapshot],
        actions: FeedRowActions,
        showsLoadMore: Bool
    ) -> some View {
        List {
            // Single chronological history stream. The plain List keeps
            // virtualization for older feed rows while active decision
            // surfaces live above it in a stable stack.
            ForEach(Array(snapshots.enumerated()), id: \.element.id) { idx, snapshot in
                rowSurface(
                    snapshot: snapshot,
                    actions: actions,
                    showsDivider: idx < snapshots.count - 1
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
            onPressSelect: {
                selectRow(snapshot.id, focusFeed: true)
            },
            onControlFocus: {
                selectRow(snapshot.id, focusFeed: false)
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
        if focusFeed || selectionChanged {
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

private struct FeedRowSurface: View {
    let snapshot: FeedItemSnapshot
    let actions: FeedRowActions
    let isSelected: Bool
    let isFocusActive: Bool
    let showsDivider: Bool
    let onPressSelect: () -> Void
    let onControlFocus: () -> Void
    let onControlBlur: () -> Void
    let onActivate: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            FeedItemRow(
                snapshot: snapshot,
                actions: actions,
                isSelected: isFocusActive,
                onPressSelect: onPressSelect,
                onControlFocus: onControlFocus,
                onControlBlur: onControlBlur,
                onActivate: onActivate
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

final class FeedKeyboardFocusView: NSView {
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
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
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
        if let mode = RightSidebarMode.modeShortcut(for: event) {
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return
        }

        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
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

/// Immutable snapshot of a `WorkstreamItem` handed to row views so rows
/// never hold a reference to the store.
struct FeedItemSnapshot: Equatable {
    let id: UUID
    let workstreamId: String
    let source: WorkstreamSource
    let kind: WorkstreamKind
    let title: String?
    let cwd: String?
    let createdAt: Date
    let status: WorkstreamStatus
    let payload: WorkstreamPayload
    let context: WorkstreamContext?
    /// Most recent user-prompt text in the same workstream, attached
    /// by the list view so every card can show a "You: …" echo for
    /// context, even when the agent payload doesn't carry it directly.
    let userPromptEcho: String?

    init(item: WorkstreamItem, userPromptEcho: String? = nil) {
        self.id = item.id
        self.workstreamId = item.workstreamId
        self.source = item.source
        self.kind = item.kind
        self.title = item.title
        self.cwd = item.cwd
        self.createdAt = item.createdAt
        self.status = item.status
        self.payload = item.payload
        self.context = item.context
        self.userPromptEcho = userPromptEcho
    }
}

/// Closure bundle; binds to `FeedCoordinator` by default.
struct FeedRowActions {
    let approvePermission: (UUID, WorkstreamPermissionMode) -> Void
    let replyQuestion: (UUID, [String]) -> Void
    let approveExitPlan: (UUID, WorkstreamExitPlanMode, String?) -> Void
    let jump: (String) -> Void
    /// Types the user's reply into the agent's terminal surface and
    /// presses Return. Used by Stop-kind cards so the user can nudge
    /// Claude without switching focus to the terminal.
    let sendText: (String, String) -> Void

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
                    _ = FeedCoordinator.shared.focusIfPossible(workstreamId: workstreamId)
                }
            },
            sendText: { workstreamId, text in
                Task { @MainActor in
                    FeedCoordinator.shared.sendTextToWorkstream(
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
    let onControlBlur: () -> Void
    let onActivate: () -> Void

    @State private var didHandlePressSelection = false

    static func == (lhs: FeedItemRow, rhs: FeedItemRow) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.isSelected == rhs.isSelected
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
                onBlurRow: onControlBlur,
                context: displayContext,
                onReply: { selections in
                    actions.replyQuestion(snapshot.id, selections)
                }
            )
        case .stop:
            StopActionArea(
                workstreamId: snapshot.workstreamId,
                isRowSelected: isSelected,
                onFocusRow: onControlFocus,
                onBlurRow: onControlBlur,
                onSend: { text in actions.sendText(snapshot.workstreamId, text) }
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

private struct FeedContextBlock: View {
    let context: WorkstreamContext
    let source: WorkstreamSource

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let user = context.lastUserMessage {
                FeedLabeledTextRow(
                    label: String(localized: "feed.context.you", defaultValue: "You:"),
                    text: user,
                    labelColor: .secondary,
                    textColor: .secondary
                )
            }
            if let preamble = context.assistantPreamble {
                FeedLabeledTextRow(
                    label: agentLabel,
                    text: preamble,
                    labelColor: .secondary,
                    textColor: .secondary,
                    rendersMarkdown: source == .claude
                )
            }
            if let plan = context.planSummary {
                FeedLabeledTextRow(
                    label: String(localized: "feed.context.plan", defaultValue: "Plan:"),
                    text: plan,
                    labelColor: Color.purple.opacity(0.85),
                    textColor: .secondary,
                    rendersMarkdown: source == .claude
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agentLabel: String {
        "\(source.rawValue.capitalized):"
    }
}

private struct FeedLabeledTextRow: View {
    let label: String
    let text: String
    let labelColor: Color
    let textColor: Color
    var rendersMarkdown: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(labelColor)
                .frame(width: 48, alignment: .leading)
            if rendersMarkdown {
                FeedMarkdownInlineText(
                    text: text,
                    fontSize: 11,
                    foregroundColor: textColor
                )
            } else {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionActionArea: View {
    let toolName: String
    let toolInputJSON: String
    let source: WorkstreamSource
    let status: WorkstreamStatus
    let onApprove: (WorkstreamPermissionMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolLabel
            codeBlock
            if status.isPending {
                HStack(spacing: 6) {
                    FeedButton(label: String(localized: "feed.permission.deny", defaultValue: "Deny"),
                               kind: .dark, size: .medium, fullWidth: true) { onApprove(.deny) }
                        .accessibilityIdentifier("FeedPermissionDenyButton")
                    FeedButton(label: String(localized: "feed.permission.once", defaultValue: "Allow Once"),
                               kind: .light, size: .medium, fullWidth: true) { onApprove(.once) }
                        .accessibilityIdentifier("FeedPermissionAllowOnceButton")
                    if source != .codex {
                        FeedButton(label: String(localized: "feed.permission.always", defaultValue: "Always Allow"),
                                   kind: .primary, size: .medium, fullWidth: true) { onApprove(.always) }
                            .accessibilityIdentifier("FeedPermissionAlwaysAllowButton")
                        FeedButton(label: String(localized: "feed.permission.bypass", defaultValue: "Bypass"),
                                   kind: .destructive, size: .medium, fullWidth: true) { onApprove(.bypass) }
                            .accessibilityIdentifier("FeedPermissionBypassButton")
                    }
                }
            } else if let badge = submittedBadge {
                FeedButton(
                    label: badge,
                    leadingIcon: "checkmark",
                    kind: .success,
                    size: .medium,
                    fullWidth: true,
                    dimmed: true
                ) {}
            }
        }
    }

    private var submittedBadge: String? {
        guard case .resolved(let decision, _) = status else { return nil }
        let submitted = String(localized: "feed.badge.submitted", defaultValue: "Submitted")
        if case .permission(let mode) = decision {
            return "\(submitted) · \(mode.displayLabel)"
        }
        return submitted
    }

    private var toolLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.orange)
            Text(toolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)
        }
    }

    private var codeBlock: some View {
        let preview = PermissionInputPreview(
            toolName: toolName,
            toolInputJSON: toolInputJSON
        )
        return VStack(alignment: .leading, spacing: 6) {
            if let primary = preview.primary {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let sigil = preview.sigil {
                        Text(sigil)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                    Text(primary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.95))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let secondary = preview.secondary, !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }
}

/// Pulls a human-readable command + description out of an agent's
/// tool_input JSON. Handles Bash (`command` + `description`), Write /
/// Edit / Read (`file_path`), and falls back to the raw JSON.
private struct PermissionInputPreview {
    let sigil: String?
    let primary: String?
    let secondary: String?

    init(toolName: String, toolInputJSON: String) {
        let dict = (try? JSONSerialization.jsonObject(
            with: Data(toolInputJSON.utf8)
        )) as? [String: Any] ?? [:]

        switch toolName.lowercased() {
        case "bash":
            self.sigil = "$"
            self.primary = (dict["command"] as? String) ?? toolInputJSON
            self.secondary = (dict["description"] as? String)
        case "write", "edit", "multiedit":
            self.sigil = nil
            self.primary = (dict["file_path"] as? String) ?? toolInputJSON
            if toolName.lowercased() == "write" {
                let content = (dict["content"] as? String) ?? ""
                let preview = content.split(separator: "\n").first.map(String.init) ?? ""
                self.secondary = preview.isEmpty ? nil : preview
            } else {
                self.secondary = nil
            }
        case "read":
            self.sigil = nil
            self.primary = (dict["file_path"] as? String) ?? toolInputJSON
            self.secondary = nil
        default:
            self.sigil = nil
            self.primary = toolInputJSON == "{}" ? nil : toolInputJSON
            self.secondary = nil
        }
    }
}

/// Single DRY button primitive used across every actionable card
/// (permission / plan / question / filter pills / option pills).
/// Replaces the old PermissionCTAButton / PlanCTAButton /
/// FeedPillButton trio so styling is defined in exactly one place.
struct FeedButton: View {
    enum Kind: String {
        /// Transparent pill that lights up on hover/selection. Used
        /// for filter bar pills and single-select option pills.
        case ghost
        /// Soft neutral fill (e.g. Manual, disabled Submit).
        case soft
        /// Dark background with white text (Deny).
        case dark
        /// Light background with black text (Allow Once).
        case light
        /// Solid blue (Always Allow, Send feedback, active Submit).
        case primary
        /// Solid green (Auto, checked multi-select option, confirmations).
        case success
        /// Solid orange (warning actions).
        case warning
        /// Solid red (destructive deny).
        case destructive
    }

    enum Size {
        case compact  // filter bar / option pills
        case medium   // full-width CTAs
    }

    let label: String
    var leadingIcon: String? = nil
    var trailingIcon: String? = nil
    var kind: Kind = .ghost
    var size: Size = .compact
    var fullWidth: Bool = false
    var isSelected: Bool = false
    var dimmed: Bool = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered: Bool = false
#if DEBUG
    @AppStorage(FeedButtonDebugSettings.generationKey) private var debugStyleGeneration = 0
#endif

    var body: some View {
#if DEBUG
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), usesSystemGlassButtonStyle {
            systemGlassButton
        } else {
            plainFeedButton
        }
        #else
        plainFeedButton
        #endif
#else
        plainFeedButton
#endif
    }

    private var plainFeedButton: some View {
        Button {
            performAction()
        } label: {
            labelContent
            .foregroundColor(foreground)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(buttonBackground)
            .overlay(buttonBorder)
            .shadow(
                color: buttonShadowColor,
                radius: buttonShadowRadius,
                x: 0,
                y: buttonShadowY
            )
            .opacity(dimmed ? 0.55 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            handleHover(hovering)
        }
        .help(label)
    }

    private var labelContent: some View {
        HStack(spacing: iconSpacing) {
            if let leadingIcon {
                Image(systemName: leadingIcon)
                    .font(.system(size: iconSize, weight: .semibold))
            }
            Text(label)
                .font(.system(size: labelSize, weight: .semibold))
            if let trailingIcon {
                Image(systemName: trailingIcon)
                    .font(.system(size: iconSize, weight: .semibold))
            }
        }
    }

    private var standardLabelContent: some View {
        HStack(spacing: 4) {
            if let leadingIcon {
                Image(systemName: leadingIcon)
            }
            Text(label)
            if let trailingIcon {
                Image(systemName: trailingIcon)
            }
        }
        .font(.system(size: labelSize, weight: .semibold))
    }

    private func performAction() {
        // `dimmed` doubles as the disabled signal — swallow the
        // click at the primitive so upstream action closures don't
        // have to re-check.
        guard !dimmed else { return }
        action()
    }

    private func handleHover(_ hovering: Bool) {
        isHovered = hovering
        // Only swap the cursor when the button is disabled —
        // enabled buttons keep the default arrow so the Feed
        // feels like the rest of the app. Pop on mouseout so a
        // stale "not allowed" cursor doesn't stick.
        if dimmed, hovering {
            NSCursor.operationNotAllowed.push()
        } else if dimmed, !hovering {
            NSCursor.pop()
        }
    }

#if DEBUG
    private var usesSystemGlassButtonStyle: Bool {
        _ = debugStyleGeneration
        switch FeedButtonDebugSettings.visualStyle {
        case .standardGlass, .standardTintedGlass, .nativeGlass, .nativeProminentGlass, .commandLight:
            return true
        case .solid, .glass, .liquid, .halo, .command, .outline, .flat:
            return false
        }
    }

    #if compiler(>=6.2)
        @available(macOS 26.0, *)
        @ViewBuilder
        private var systemGlassButton: some View {
            if FeedButtonDebugSettings.visualStyle == .standardGlass {
                standardSystemGlassButtonBase
                    .buttonStyle(.glass)
            } else if FeedButtonDebugSettings.visualStyle == .standardTintedGlass {
                standardSystemGlassButtonBase
                    .buttonStyle(.glass)
                    .tint(systemGlassTint)
            } else if FeedButtonDebugSettings.visualStyle == .nativeProminentGlass {
                systemGlassButtonBase
                    .buttonStyle(.glassProminent)
            } else {
                systemGlassButtonBase
                    .buttonStyle(.glass)
            }
        }

        @available(macOS 26.0, *)
        private var standardSystemGlassButtonBase: some View {
            Button {
                performAction()
            } label: {
                standardLabelContent
                    .frame(maxWidth: fullWidth ? .infinity : nil)
            }
            .controlSize(size == .compact ? .small : .regular)
            .disabled(dimmed)
            .opacity(dimmed ? 0.55 : 1.0)
            .onHover { hovering in
                handleHover(hovering)
            }
            .help(label)
        }

        @available(macOS 26.0, *)
        private var systemGlassButtonBase: some View {
            Button {
                performAction()
            } label: {
                labelContent
                    .foregroundStyle(systemGlassForeground)
                    .frame(maxWidth: fullWidth ? .infinity : nil)
                    .padding(.horizontal, max(CGFloat(0), horizontalPadding - 2))
                    .padding(.vertical, max(CGFloat(0), verticalPadding - 1))
                    .contentShape(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            }
            .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
            .controlSize(size == .compact ? .small : .regular)
            .tint(systemGlassTint)
            .disabled(dimmed)
            .opacity(dimmed ? 0.55 : 1.0)
            .onHover { hovering in
                handleHover(hovering)
            }
            .help(label)
        }
    #endif

    private var systemGlassTint: Color {
        glassEffectTint.opacity(FeedButtonDebugSettings.glassTintOpacity)
    }

    private var systemGlassForeground: Color {
        if let color = FeedButtonDebugSettings.color(
            for: kind,
            role: .foreground,
            colorScheme: colorScheme
        ) {
            return color
        }

        switch FeedButtonDebugSettings.visualStyle {
        case .nativeProminentGlass:
            return kind == .light ? .black : .white
        case .nativeGlass:
            return .primary
        case .standardGlass, .standardTintedGlass, .solid, .glass, .liquid, .halo, .command, .commandLight, .outline, .flat:
            return foreground
        }
    }
#endif

    // MARK: - Style resolution

    private var labelSize: CGFloat { size == .compact ? 10 : 10.5 }
    private var iconSize: CGFloat { size == .compact ? 9 : 10 }
    private var iconSpacing: CGFloat { size == .compact ? 3 : 5 }
    private var cornerRadius: CGFloat {
#if DEBUG
        _ = debugStyleGeneration
        return size == .compact
            ? CGFloat(FeedButtonDebugSettings.compactCornerRadius)
            : CGFloat(FeedButtonDebugSettings.mediumCornerRadius)
#else
        return size == .compact ? 5 : 6
#endif
    }
    private var horizontalPadding: CGFloat {
#if DEBUG
        _ = debugStyleGeneration
        return size == .compact
            ? CGFloat(FeedButtonDebugSettings.compactHorizontalPadding)
            : CGFloat(FeedButtonDebugSettings.mediumHorizontalPadding)
#else
        return size == .compact ? 8 : 12
#endif
    }
    private var verticalPadding: CGFloat {
#if DEBUG
        _ = debugStyleGeneration
        return size == .compact
            ? CGFloat(FeedButtonDebugSettings.compactVerticalPadding)
            : CGFloat(FeedButtonDebugSettings.mediumVerticalPadding)
#else
        return size == .compact ? 4 : 5
#endif
    }

    private var foreground: Color {
#if DEBUG
        _ = debugStyleGeneration
        if let color = FeedButtonDebugSettings.color(
            for: kind,
            role: .foreground,
            colorScheme: colorScheme
        ) {
            return color
        }
#endif
        switch kind {
        case .ghost:
            return isSelected ? .primary : .primary.opacity(0.85)
        case .soft: return .primary
        case .dark: return .white
        case .light: return .black
        case .primary: return .white
        case .success: return .white
        case .warning: return .white
        case .destructive: return .white
        }
    }

    private var backgroundFill: Color {
#if DEBUG
        _ = debugStyleGeneration
        if let color = FeedButtonDebugSettings.color(
            for: kind,
            role: isHovered ? .hoverBackground : .background,
            colorScheme: colorScheme
        ) {
            return color
        }
#endif
        switch kind {
        case .ghost:
            if isSelected { return Color.primary.opacity(0.12) }
            if isHovered { return Color.primary.opacity(0.06) }
            return Color.clear
        case .soft:
            return isHovered ? Color.primary.opacity(0.16) : Color.primary.opacity(0.10)
        case .dark:
            return isHovered ? Color.black.opacity(0.85) : Color.black.opacity(0.75)
        case .light:
            return isHovered ? Color.white.opacity(0.96) : Color.white.opacity(0.88)
        case .primary:
            return isHovered
                ? Color(red: 0.28, green: 0.55, blue: 0.95)
                : Color(red: 0.24, green: 0.48, blue: 0.88)
        case .success:
            return isHovered
                ? Color(red: 0.22, green: 0.72, blue: 0.42)
                : Color(red: 0.18, green: 0.62, blue: 0.35)
        case .warning:
            return isHovered
                ? Color(red: 0.95, green: 0.55, blue: 0.18)
                : Color(red: 0.92, green: 0.54, blue: 0.29)
        case .destructive:
            return isHovered
                ? Color(red: 0.85, green: 0.28, blue: 0.28)
                : Color(red: 0.75, green: 0.22, blue: 0.22)
        }
    }

#if DEBUG
    private var glassEffectTint: Color {
        _ = debugStyleGeneration
        if let color = FeedButtonDebugSettings.color(
            for: kind,
            role: isHovered ? .hoverBackground : .background,
            colorScheme: colorScheme
        ) {
            return color
        }

        switch kind {
        case .ghost: return Color.accentColor
        case .soft: return Color.gray
        case .dark: return Color.black
        case .light: return Color.white
        case .primary: return Color(red: 0.24, green: 0.48, blue: 0.88)
        case .success: return Color(red: 0.18, green: 0.62, blue: 0.35)
        case .warning: return Color(red: 0.92, green: 0.54, blue: 0.29)
        case .destructive: return Color(red: 0.75, green: 0.22, blue: 0.22)
        }
    }
#endif

    @ViewBuilder
    private var buttonBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
#if DEBUG
        let generation = debugStyleGeneration
        switch generation >= 0 ? FeedButtonDebugSettings.visualStyle : .solid {
        case .solid:
            shape.fill(backgroundFill)
        case .standardGlass:
            shape.fill(.regularMaterial)
        case .standardTintedGlass:
            shape
                .fill(.regularMaterial)
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
        case .glass:
            shape
                .fill(.thinMaterial)
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
        case .nativeGlass:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                shape
                    .fill(Color.clear)
                    .glassEffect(
                        .regular
                            .tint(glassEffectTint.opacity(FeedButtonDebugSettings.glassTintOpacity))
                            .interactive(!dimmed),
                        in: shape
                    )
            } else {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(backgroundFill.opacity(0.20)))
            }
            #else
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(backgroundFill.opacity(0.20)))
            #endif
        case .nativeProminentGlass:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                shape
                    .fill(Color.clear)
                    .glassEffect(
                        .regular
                            .tint(glassEffectTint.opacity(FeedButtonDebugSettings.glassTintOpacity))
                            .interactive(!dimmed),
                        in: shape
                    )
                    .overlay(
                        shape.fill(
                            backgroundFill.opacity(isHovered || isSelected ? 0.30 : 0.18)
                        )
                    )
            } else {
                shape
                    .fill(.regularMaterial)
                    .overlay(shape.fill(backgroundFill.opacity(0.26)))
            }
            #else
            shape
                .fill(.regularMaterial)
                .overlay(shape.fill(backgroundFill.opacity(0.26)))
            #endif
        case .liquid:
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered || isSelected ? 0.42 : 0.30),
                                Color.white.opacity(0.08),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.screen)
                )
        case .halo:
            shape
                .fill(.thinMaterial)
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
                .overlay(
                    shape.fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(isHovered || isSelected ? 0.30 : 0.18),
                                Color.clear,
                            ],
                            center: .topLeading,
                            startRadius: 1,
                            endRadius: 54
                        )
                    )
                    .blendMode(.screen)
                )
        case .command:
            shape
                .fill(.regularMaterial)
                .overlay(shape.fill(Color.black.opacity(0.28)))
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
        case .commandLight:
            shape
                .fill(.regularMaterial)
                .overlay(shape.fill(Color.white.opacity(0.22)))
                .overlay(
                    shape.fill(
                        backgroundFill.opacity(
                            FeedButtonDebugSettings.glassTintOpacity
                        )
                    )
                )
        case .outline:
            shape.fill(isHovered || isSelected ? backgroundFill.opacity(0.14) : Color.clear)
        case .flat:
            shape.fill(isHovered || isSelected ? backgroundFill.opacity(0.12) : Color.clear)
        }
#else
        shape.fill(backgroundFill)
#endif
    }

    @ViewBuilder
    private var buttonBorder: some View {
#if DEBUG
        let generation = debugStyleGeneration
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch generation >= 0 ? FeedButtonDebugSettings.visualStyle : .solid {
        case .solid:
            EmptyView()
        case .standardGlass:
            shape.stroke(Color.white.opacity(0.12), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .standardTintedGlass:
            shape.stroke(backgroundFill.opacity(0.22), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .glass:
            shape.stroke(Color.white.opacity(0.16), lineWidth: 0.75)
        case .nativeGlass:
            shape.stroke(Color.white.opacity(0.14), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .nativeProminentGlass:
            shape.stroke(Color.white.opacity(0.18), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .liquid:
            shape.stroke(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.42),
                        backgroundFill.opacity(0.28),
                        Color.white.opacity(0.10),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: FeedButtonDebugSettings.borderWidth
            )
        case .halo:
            shape.stroke(
                backgroundFill.opacity(isHovered || isSelected ? 0.55 : 0.34),
                lineWidth: FeedButtonDebugSettings.borderWidth
            )
        case .command:
            shape.stroke(Color.white.opacity(0.12), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .commandLight:
            shape.stroke(Color.black.opacity(0.12), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .outline:
            shape.stroke(backgroundFill.opacity(0.75), lineWidth: FeedButtonDebugSettings.borderWidth)
        case .flat:
            EmptyView()
        }
#else
        EmptyView()
#endif
    }

    private var buttonShadowColor: Color {
#if DEBUG
        _ = debugStyleGeneration
        switch FeedButtonDebugSettings.visualStyle {
        case .halo:
            return backgroundFill.opacity(isHovered || isSelected ? 0.44 : 0.24)
        case .liquid:
            return backgroundFill.opacity(isHovered || isSelected ? 0.18 : 0.10)
        case .command:
            return Color.black.opacity(0.28)
        case .commandLight:
            return Color.black.opacity(isHovered || isSelected ? 0.16 : 0.08)
        case .nativeProminentGlass:
            return backgroundFill.opacity(isHovered || isSelected ? 0.18 : 0.10)
        case .standardGlass, .standardTintedGlass, .solid, .glass, .nativeGlass, .outline, .flat:
            return Color.clear
        }
#else
        return Color.clear
#endif
    }

    private var buttonShadowRadius: CGFloat {
#if DEBUG
        _ = debugStyleGeneration
        switch FeedButtonDebugSettings.visualStyle {
        case .halo: return isHovered || isSelected ? 9 : 6
        case .liquid: return isHovered || isSelected ? 5 : 3
        case .nativeProminentGlass: return isHovered || isSelected ? 5 : 3
        case .command: return 3
        case .commandLight: return isHovered || isSelected ? 4 : 2
        case .standardGlass, .standardTintedGlass, .solid, .glass, .nativeGlass, .outline, .flat: return 0
        }
#else
        return 0
#endif
    }

    private var buttonShadowY: CGFloat {
#if DEBUG
        _ = debugStyleGeneration
        switch FeedButtonDebugSettings.visualStyle {
        case .halo: return 2
        case .liquid, .nativeProminentGlass, .command, .commandLight: return 1
        case .standardGlass, .standardTintedGlass, .solid, .glass, .nativeGlass, .outline, .flat: return 0
        }
#else
        return 0
#endif
    }
}

private struct ExitPlanActionArea: View {
    let plan: String
    let source: WorkstreamSource
    let status: WorkstreamStatus
    let isRowSelected: Bool
    let onFocusRow: () -> Void
    let onBlurRow: () -> Void
    let onApprove: (WorkstreamExitPlanMode, String?) -> Void

    @State private var feedback: String = ""
    @FocusState private var feedbackFocused: Bool

    private var trimmedFeedback: String {
        feedback.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var hasFeedback: Bool { !trimmedFeedback.isEmpty }
    private var preview: WorkstreamExitPlanPreview {
        WorkstreamExitPlanPreview(rawPlan: plan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlanBodyView(
                plan: preview.planText,
                rendersMarkdown: source == .claude
            )
            if !preview.allowedPrompts.isEmpty {
                ExitPlanAllowedPromptsView(prompts: preview.allowedPrompts)
            }
            if let path = preview.planFilePath {
                ExitPlanPlanFileView(path: path)
            }
            if status.isPending {
                TextField(
                    String(
                        localized: "feed.exitplan.feedback.placeholder",
                        defaultValue: "Tell Claude what to change…"
                    ),
                    text: $feedback,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .tint(Color.primary.opacity(0.75))
                .focused($feedbackFocused)
                .lineLimit(2...5)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(feedbackFocused ? 0.075 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            Color.primary.opacity(feedbackFocused ? 0.20 : (hasFeedback ? 0.25 : 0.10)),
                            lineWidth: 1
                        )
                )
                .onChange(of: feedbackFocused) { _, focused in
                    if focused {
                        onFocusRow()
                    } else {
                        onBlurRow()
                    }
                }
                HStack(spacing: 6) {
                    FeedButton(
                        label: hasFeedback
                            ? String(localized: "feed.exitplan.refine",
                                     defaultValue: "Send feedback")
                            : String(localized: "feed.exitplan.ultraplan",
                                     defaultValue: "Ultraplan"),
                        kind: hasFeedback ? .primary : .soft,
                        size: .medium, fullWidth: true
                    ) {
                        onFocusRow()
                        // Feedback always wins over mode; hook translates
                        // non-empty feedback into block+reason.
                        onApprove(hasFeedback ? .manual : .ultraplan, hasFeedback ? trimmedFeedback : nil)
                    }
                    FeedButton(
                        label: String(localized: "feed.exitplan.manual",
                                      defaultValue: "Manual"),
                        kind: .soft,
                        size: .medium, fullWidth: true,
                        dimmed: hasFeedback
                    ) {
                        onFocusRow()
                        onApprove(.manual, hasFeedback ? trimmedFeedback : nil)
                    }
                    FeedButton(
                        label: String(localized: "feed.exitplan.auto",
                                      defaultValue: "Auto"),
                        kind: .success,
                        size: .medium, fullWidth: true,
                        dimmed: hasFeedback
                    ) {
                        onFocusRow()
                        onApprove(.autoAccept, hasFeedback ? trimmedFeedback : nil)
                    }
                }
            } else if let badge = submittedBadge {
                FeedButton(
                    label: badge,
                    leadingIcon: "checkmark",
                    kind: .success,
                    size: .medium,
                    fullWidth: true,
                    dimmed: true
                ) {}
            }
        }
        .onChange(of: isRowSelected) { _, selected in
            if !selected {
                feedbackFocused = false
            }
        }
    }

    private var submittedBadge: String? {
        guard case .resolved(let decision, _) = status else { return nil }
        let submitted = String(localized: "feed.badge.submitted", defaultValue: "Submitted")
        switch decision {
        case .exitPlan(let mode, let feedback):
            if let feedback, !feedback.isEmpty {
                return "\(submitted) · " + String(
                    localized: "feed.badge.refined", defaultValue: "refined"
                )
            }
            return "\(submitted) · \(mode.displayLabel)"
        default:
            return submitted
        }
    }
}

private struct ExitPlanAllowedPromptsView: View {
    let prompts: [WorkstreamAllowedPrompt]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.purple.opacity(0.85))
                Text(String(localized: "feed.exitplan.allowedPrompts", defaultValue: "Allowed prompts"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.purple.opacity(0.9))
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { _, prompt in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if !prompt.tool.isEmpty {
                            Text(prompt.tool)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.purple)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.purple.opacity(0.14))
                                )
                        }
                        Text(prompt.prompt)
                            .font(.system(size: 11))
                            .foregroundColor(.primary.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.purple.opacity(0.06))
            )
        }
    }
}

private struct ExitPlanPlanFileView: View {
    let path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(String(localized: "feed.exitplan.planFile", defaultValue: "Plan file"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
        }
    }
}

private struct FeedMarkdownInlineText: View {
    let text: String
    let fontSize: CGFloat
    let weight: Font.Weight?
    let foregroundColor: Color

    init(
        text: String,
        fontSize: CGFloat,
        weight: Font.Weight? = nil,
        foregroundColor: Color
    ) {
        self.text = text
        self.fontSize = fontSize
        self.weight = weight
        self.foregroundColor = foregroundColor
    }

    var body: some View {
        let parsed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
        let font = weight.map { Font.system(size: fontSize, weight: $0) }
            ?? Font.system(size: fontSize)
        Text(parsed)
            .font(font)
            .foregroundColor(foregroundColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Renders plan text as a stack of small structured sections. Block
/// headings, lists, and paragraphs keep the Feed's compact rhythm, while
/// Claude markdown inside each line gets parsed tastefully. Heading text
/// intentionally stays at body scale.
private struct PlanBodyView: View {
    let plan: String
    let rendersMarkdown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    markdownText(
                        text,
                        weight: .semibold,
                        color: .primary.opacity(0.95)
                    )
                        .padding(.top, 2)
                case .paragraph(let text):
                    markdownText(text, color: .primary.opacity(0.85))
                case .numbered(let items):
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 5) {
                                Text("\(item.index).")
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundColor(.secondary)
                                markdownText(item.text, color: .primary.opacity(0.85))
                            }
                        }
                    }
                case .bulleted(let items):
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Color.blue.opacity(0.85))
                                    .frame(width: 3.5, height: 3.5)
                                    .padding(.top, 5.5)
                                    .frame(width: 10, alignment: .center)
                                markdownText(item, color: .primary.opacity(0.85))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func markdownText(
        _ text: String,
        weight: Font.Weight? = nil,
        color: Color
    ) -> some View {
        if rendersMarkdown {
            FeedMarkdownInlineText(
                text: text,
                fontSize: 11,
                weight: weight,
                foregroundColor: color
            )
        } else {
            Text(text)
                .font(.system(size: 11, weight: weight ?? .regular))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private enum Block {
        case heading(String)
        case paragraph(String)
        case numbered([NumberedItem])
        case bulleted([String])
    }

    private struct NumberedItem {
        let index: Int
        let text: String
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var buffer: [String] = []
        func flushParagraph() {
            guard !buffer.isEmpty else { return }
            let joined = buffer.joined(separator: " ")
            out.append(.paragraph(joined))
            buffer = []
        }
        var numbered: [NumberedItem] = []
        func flushNumbered() {
            if !numbered.isEmpty {
                out.append(.numbered(numbered))
                numbered = []
            }
        }
        var bulleted: [String] = []
        func flushBulleted() {
            if !bulleted.isEmpty {
                out.append(.bulleted(bulleted))
                bulleted = []
            }
        }

        for rawLine in plan.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph(); flushNumbered(); flushBulleted()
                continue
            }
            // **Bold heading** or ## heading or "Word:" on its own line
            if line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4 {
                flushParagraph(); flushNumbered(); flushBulleted()
                out.append(.heading(String(line.dropFirst(2).dropLast(2))))
                continue
            }
            if let heading = markdownHeadingText(line) {
                flushParagraph(); flushNumbered(); flushBulleted()
                out.append(.heading(heading))
                continue
            }
            if line.hasSuffix(":") && line.count <= 40
               && !line.contains(" ") == false && line.split(separator: " ").count <= 4
            {
                flushParagraph(); flushNumbered(); flushBulleted()
                out.append(.heading(line))
                continue
            }
            // Numbered list
            if let match = line.range(
                of: #"^(\d+)\.\s+(.+)$"#,
                options: .regularExpression
            ) {
                flushParagraph(); flushBulleted()
                let text = String(line[match])
                if let dotIdx = text.firstIndex(of: ".") {
                    let numStr = String(text[text.startIndex..<dotIdx])
                    let content = String(text[text.index(after: dotIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                    numbered.append(NumberedItem(
                        index: Int(numStr) ?? (numbered.count + 1),
                        text: content
                    ))
                }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") {
                flushParagraph(); flushNumbered()
                let text = String(line.dropFirst(2))
                bulleted.append(text)
                continue
            }
            buffer.append(line)
        }
        flushParagraph(); flushNumbered(); flushBulleted()
        return out
    }

    private func markdownHeadingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let hashCount = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashCount),
              line.count > hashCount,
              line[line.index(line.startIndex, offsetBy: hashCount)] == " "
        else { return nil }
        return String(line.dropFirst(hashCount + 1))
    }
}

private struct QuestionActionArea: View {
    let questions: [WorkstreamQuestionPrompt]
    let source: WorkstreamSource
    let status: WorkstreamStatus
    let isRowSelected: Bool
    let onFocusRow: () -> Void
    let onBlurRow: () -> Void
    let context: WorkstreamContext?
    let onReply: ([String]) -> Void

    private static let skipInterviewAndPlanAnswer = "Skip interview and plan immediately"
    private static let customAnswerSelectionId = "__cmux_custom_answer__"

    // Per-question selections keyed by question id.
    @State private var selections: [String: Set<String>] = [:]
    // Per-question "Type something…" free-form answers. When
    // non-empty, wins over preset option selections for that
    // question — mirrors Claude's TUI fallback.
    @State private var freeTexts: [String: String] = [:]
    @State private var focusedCustomAnswerId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shouldRenderLongForm, let q = questions.first {
                longFormBlock(question: q)
            } else {
                ForEach(Array(questions.enumerated()), id: \.offset) { idx, q in
                    questionBlock(index: idx + 1, question: q)
                }
            }
            if shouldShowSkipInterviewCTA {
                HStack(spacing: 8) {
                    skipInterviewCTA
                    submitCTA
                }
            } else {
                submitCTA
            }
        }
        .onChange(of: isRowSelected) { _, selected in
            if !selected {
                clearCustomAnswerFocus()
            }
        }
    }

    private var shouldRenderLongForm: Bool {
        // Long-form: single question whose options carry descriptions
        // (e.g. Claude's AskUserQuestion with `header` + per-option
        // detail). Multi-option list with a bigger rich-text card per
        // option, click-to-select.
        guard questions.count == 1, let q = questions.first else { return false }
        return q.options.contains { $0.description?.isEmpty == false }
    }

    private var agentLabel: String {
        "\(source.rawValue.capitalized):"
    }

    /// Long-form rendering: single question with rich options. Each
    /// option becomes a tappable card with numbered index, title, and
    /// description. Selecting only updates local state; the Submit
    /// button sends the answer.
    @ViewBuilder
    private func longFormBlock(question: WorkstreamQuestionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !question.prompt.isEmpty {
                FeedLabeledTextRow(
                    label: agentLabel,
                    text: question.prompt,
                    labelColor: .secondary,
                    textColor: .primary.opacity(0.95)
                )
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) { idx, option in
                longFormOptionCard(
                    questionId: question.id,
                    multi: question.multiSelect,
                    index: idx + 1,
                    option: option
                )
            }
            if status.isPending {
                longFormCustomAnswerCard(
                    questionId: question.id,
                    multi: question.multiSelect,
                    index: question.options.count + 1
                )
            }
        }
    }

    private func longFormOptionCard(
        questionId: String,
        multi: Bool,
        index: Int,
        option: WorkstreamQuestionOption
    ) -> some View {
        let selected = selections[questionId]?.contains(option.id) == true
        return Button {
            guard status.isPending else { return }
            onFocusRow()
            clearCustomAnswerFocus()
            var current = selections[questionId] ?? []
            if multi {
                if current.contains(option.id) {
                    current.remove(option.id)
                } else {
                    current.insert(option.id)
                }
            } else {
                current = [option.id]
            }
            selections[questionId] = current
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundColor(selected ? .white : .secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(selected ? Color(red: 0.24, green: 0.48, blue: 0.88) : Color.primary.opacity(0.08))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(selected ? Color(red: 0.24, green: 0.48, blue: 0.88) : .secondary.opacity(0.45))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color(red: 0.24, green: 0.48, blue: 0.88).opacity(0.14) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(selected ? Color(red: 0.24, green: 0.48, blue: 0.88).opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!status.isPending)
    }

    private func longFormCustomAnswerCard(
        questionId: String,
        multi: Bool,
        index: Int
    ) -> some View {
        let customId = Self.customAnswerSelectionId
        let selected = selections[questionId]?.contains(customId) == true
        let focusKey = customAnswerFocusKey(questionId)
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundColor(selected ? .white : .secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selected ? Color(red: 0.24, green: 0.48, blue: 0.88) : Color.primary.opacity(0.08))
                )
            customAnswerField(
                text: customAnswerBinding(questionId: questionId, multi: multi),
                isFocused: customAnswerFocusBinding(focusKey),
                font: font,
                onFocus: {
                    onFocusRow()
                    selectCustomAnswer(questionId: questionId, multi: multi)
                },
                onBlur: onBlurRow
            )
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(selected ? Color(red: 0.24, green: 0.48, blue: 0.88) : .secondary.opacity(0.45))
                .padding(.leading, 8)
                .padding(.top, 3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color(red: 0.24, green: 0.48, blue: 0.88).opacity(0.14) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(selected ? Color(red: 0.24, green: 0.48, blue: 0.88).opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard status.isPending else { return }
            onFocusRow()
            selectCustomAnswer(questionId: questionId, multi: multi)
            focusedCustomAnswerId = focusKey
        }
        .feedIBeamCursorOnHover(enabled: status.isPending)
        .disabled(!status.isPending)
    }

    private func questionBlock(index: Int, question: WorkstreamQuestionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 5) {
                Text("\(index).")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(.blue)
                Text(question.prompt)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.multiSelect {
                HStack(spacing: 3) {
                    Image(systemName: "checklist")
                        .font(.system(size: 8, weight: .medium))
                    Text(String(localized: "feed.question.multiSelect", defaultValue: "Multi-select"))
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.3)
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.orange.opacity(0.18))
                )
            }
            if question.options.isEmpty {
                Text(String(localized: "feed.question.noOptions",
                            defaultValue: "Agent provided no options."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                WrapHStack(spacing: 6) {
                    ForEach(question.options, id: \.id) { option in
                        optionPill(questionId: question.id, option: option, multi: question.multiSelect)
                    }
                }
            }
            if status.isPending {
                freeFormField(questionId: question.id, multi: question.multiSelect)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// "Type something…" free-form text field — mirrors Claude's TUI
    /// option 4 (custom answer). When non-empty it wins over the
    /// preset option selection for that question on submit.
    private func freeFormField(questionId: String, multi: Bool) -> some View {
        let focusKey = customAnswerFocusKey(questionId)
        let font = NSFont.systemFont(ofSize: 11)
        return customAnswerField(
            text: customAnswerBinding(questionId: questionId, multi: multi),
            isFocused: customAnswerFocusBinding(focusKey),
            font: font,
            onFocus: {
                onFocusRow()
                selectCustomAnswer(questionId: questionId, multi: multi)
            },
            onBlur: onBlurRow
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .feedIBeamCursorOnHover(enabled: status.isPending)
        .onTapGesture {
            guard status.isPending else { return }
            onFocusRow()
            selectCustomAnswer(questionId: questionId, multi: multi)
            focusedCustomAnswerId = focusKey
        }
    }

    private func customAnswerField(
        text: Binding<String>,
        isFocused: Binding<Bool>,
        font: NSFont,
        onFocus: @escaping () -> Void,
        onBlur: @escaping () -> Void
    ) -> some View {
        FeedInlineTextField(
            text: text,
            isFocused: isFocused,
            placeholder: String(localized: "feed.question.typeSomething",
                                defaultValue: "Type something..."),
            isEnabled: status.isPending,
            font: font,
            onFocus: onFocus,
            onBlur: onBlur
        )
        .frame(
            maxWidth: .infinity,
            minHeight: FeedInlineTextEditorView.minimumHeight(for: font),
            alignment: .leading
        )
        .layoutPriority(1)
    }

    private func customAnswerBinding(questionId: String, multi: Bool) -> Binding<String> {
        Binding<String>(
            get: { freeTexts[questionId] ?? "" },
            set: { value in
                freeTexts[questionId] = value
                var current = selections[questionId] ?? []
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    current.remove(Self.customAnswerSelectionId)
                } else if multi {
                    current.insert(Self.customAnswerSelectionId)
                } else {
                    current = [Self.customAnswerSelectionId]
                }
                selections[questionId] = current
            }
        )
    }

    private func customAnswerFocusBinding(_ focusKey: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { focusedCustomAnswerId == focusKey },
            set: { focused in
                if focused {
                    focusedCustomAnswerId = focusKey
                } else if focusedCustomAnswerId == focusKey {
                    focusedCustomAnswerId = nil
                }
            }
        )
    }

    private func customAnswerFocusKey(_ questionId: String) -> String {
        "\(questionId)::custom"
    }

    private func selectCustomAnswer(questionId: String, multi: Bool) {
        var current = selections[questionId] ?? []
        if multi {
            current.insert(Self.customAnswerSelectionId)
        } else {
            current = [Self.customAnswerSelectionId]
        }
        selections[questionId] = current
    }

    private func clearCustomAnswerFocus() {
        focusedCustomAnswerId = nil
    }

    private func optionPill(
        questionId: String,
        option: WorkstreamQuestionOption,
        multi: Bool
    ) -> some View {
        let selected = selections[questionId]?.contains(option.id) == true
        let leading: String? = multi
            ? (selected ? "checkmark.square.fill" : "square")
            : nil
        let selectedKind: FeedButton.Kind = multi ? .success : .primary
        return FeedButton(
            label: option.label,
            leadingIcon: leading,
            kind: selected ? selectedKind : .soft,
            size: .compact,
            dimmed: !status.isPending
        ) {
            guard status.isPending else { return }
            onFocusRow()
            clearCustomAnswerFocus()
            var current = selections[questionId] ?? []
            if multi {
                if current.contains(option.id) { current.remove(option.id) }
                else { current.insert(option.id) }
            } else {
                current = [option.id]
            }
            selections[questionId] = current
        }
    }

    /// One answer string per question: the user's free-form text if
    /// they typed any, otherwise the labels of the selected options
    /// joined by ", ". Questions with no answer are omitted entirely
    /// so the agent doesn't see "question 2: <empty>".
    private var composedAnswers: [String] {
        var out: [String] = []
        for q in questions {
            let freeText = (freeTexts[q.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = selections[q.id] ?? []
            if !freeText.isEmpty, ids.contains(Self.customAnswerSelectionId) {
                out.append(freeText)
                continue
            }
            guard !ids.isEmpty else { continue }
            let labels = q.options
                .filter { ids.contains($0.id) }
                .map(\.label)
            if !labels.isEmpty {
                out.append(labels.joined(separator: ", "))
            }
        }
        return out
    }

    private var hasAnyAnswer: Bool { !composedAnswers.isEmpty }

    private var canSubmitEmptyAnswer: Bool {
        !questions.isEmpty && questions.allSatisfy { $0.options.isEmpty }
    }

    private var shouldShowSkipInterviewCTA: Bool {
        status.isPending && isPlanAskUserQuestion
    }

    private var isPlanAskUserQuestion: Bool {
        guard source == .claude else { return false }
        if let mode = context?.permissionMode {
            return mode.caseInsensitiveCompare("plan") == .orderedSame
        }
        return questionTextLooksLikePlanInterview
    }

    private var questionTextLooksLikePlanInterview: Bool {
        let fragments: [String?] = questions.flatMap { q in
            let questionFragments: [String?] = [q.header, q.prompt]
            let optionFragments: [String?] = q.options.flatMap { option in
                [option.label, option.description]
            }
            return questionFragments + optionFragments
        }
        let text = ([context?.lastUserMessage, context?.assistantPreamble] + fragments)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return text.contains("plan mode")
            || text.contains("make a plan")
            || text.contains("plan-only")
            || text.contains("plan immediately")
    }

    private var submitCTA: some View {
        let isPending = status.isPending
        let enabled = isPending && (hasAnyAnswer || canSubmitEmptyAnswer)
        return FeedButton(
            label: isPending
                ? String(localized: "feed.question.submitAll",
                         defaultValue: "Submit All Answers")
                : String(localized: "feed.badge.submitted",
                         defaultValue: "Submitted"),
            leadingIcon: isPending ? "checkmark.circle.fill" : "checkmark",
            kind: enabled ? .primary : (isPending ? .soft : .success),
            size: .medium,
            fullWidth: true,
            dimmed: !enabled
        ) {
            onFocusRow()
            // Selections carry human-readable answer strings (one per
            // answered question) so the hook can feed them straight
            // back to the agent as the user's reply.
            onReply(composedAnswers)
        }
    }

    private var skipInterviewCTA: some View {
        FeedButton(
            label: String(localized: "feed.question.skipInterviewPlan",
                          defaultValue: "Skip + plan immediately"),
            leadingIcon: "forward.end.fill",
            kind: .soft,
            size: .medium,
            fullWidth: true
        ) {
            onFocusRow()
            onReply([Self.skipInterviewAndPlanAnswer])
        }
    }
}

private final class FeedInlinePassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FeedInlineNativeTextView: NSTextView, FeedKeyboardFocusResponder {
    private static weak var activeEditor: FeedInlineNativeTextView?

    var onActivate: (() -> Void)?
    var onEscape: (() -> Void)?

    static func blurActiveEditor() {
        guard let activeEditor else { return }
        guard let window = activeEditor.window else {
            if Self.activeEditor === activeEditor {
                Self.activeEditor = nil
            }
            return
        }
        guard window.firstResponder === activeEditor else {
            if Self.activeEditor === activeEditor {
                Self.activeEditor = nil
            }
            return
        }
#if DEBUG
        dlog("feed.editor.blurActive fr=\(feedDebugResponderSummary(window.firstResponder))")
#endif
        window.makeFirstResponder(nil)
    }

    override func mouseDown(with event: NSEvent) {
#if DEBUG
        dlog("feed.editor.mouseDown frBefore=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        onActivate?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
#if DEBUG
            dlog("feed.editor.escape fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            Self.activeEditor = self
            onActivate?()
        }
#if DEBUG
        dlog("feed.editor.become result=\(didBecomeFirstResponder ? 1 : 0) fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder, Self.activeEditor === self {
            Self.activeEditor = nil
        }
#if DEBUG
        dlog("feed.editor.resign result=\(didResignFirstResponder ? 1 : 0) fr=\(feedDebugResponderSummary(window?.firstResponder))")
#endif
        return didResignFirstResponder
    }
}

private final class FeedInlineTextEditorView: NSView {
    private static let textInset = NSSize(width: 0, height: 1)

    let textView = FeedInlineNativeTextView(frame: .zero)
    private let placeholderField = FeedInlinePassthroughLabel(labelWithString: "")
    private var currentFont = NSFont.systemFont(ofSize: 11)

    static func minimumHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + textInset.height * 2
    }

    var placeholder: String = "" {
        didSet {
            guard placeholder != oldValue else { return }
            placeholderField.stringValue = placeholder
            updatePlaceholderVisibility()
        }
    }

    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            textView.isEditable = isEnabled
            textView.isSelectable = isEnabled
            textView.textColor = isEnabled ? .labelColor : .disabledControlTextColor
            textView.insertionPointColor = .controlAccentColor
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        addSubview(textView)

        placeholderField.textColor = .placeholderTextColor
        placeholderField.lineBreakMode = .byWordWrapping
        placeholderField.maximumNumberOfLines = 0
        addSubview(placeholderField)

        apply(font: currentFont, isEnabled: true)
        updatePlaceholderVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight())
    }

    override func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        let availableWidth = max(bounds.width, 1)
        let height = fittingHeight(for: availableWidth)
        textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: height)
        placeholderField.frame = NSRect(
            x: Self.textInset.width,
            y: Self.textInset.height,
            width: max(bounds.width - Self.textInset.width * 2, 1),
            height: Self.minimumHeight(for: currentFont)
        )
    }

    func apply(font: NSFont, isEnabled: Bool) {
        let fontChanged = currentFont != font || textView.font != font || placeholderField.font != font
        let enabledChanged = self.isEnabled != isEnabled

        if fontChanged {
            currentFont = font
            textView.font = font
            placeholderField.font = font
            textView.textColor = self.isEnabled ? .labelColor : .disabledControlTextColor
            textView.insertionPointColor = .controlAccentColor
        }
        if enabledChanged {
            self.isEnabled = isEnabled
        }
        if fontChanged || enabledChanged {
            refreshMetrics()
        }
    }

    func refreshMetrics() {
        updatePlaceholderVisibility()
        needsLayout = true
        invalidateIntrinsicContentSize()
        layoutSubtreeIfNeeded()
    }

    func focusIfNeeded() {
        guard let window, window.firstResponder !== textView else { return }
        window.makeFirstResponder(textView)
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: length, length: 0))
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return Self.minimumHeight(for: currentFont)
        }
        let availableWidth = max(width - Self.textInset.width * 2, 1)
        textContainer.containerSize = NSSize(
            width: availableWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let lineHeight = ceil(currentFont.ascender - currentFont.descender + currentFont.leading)
        let contentHeight = max(lineHeight, ceil(usedRect.height))
        return max(
            Self.minimumHeight(for: currentFont),
            ceil(contentHeight + Self.textInset.height * 2)
        )
    }

    private func updateTextViewLayout() {
        let availableWidth = max(bounds.width, 1)
        let height = fittingHeight(for: availableWidth)
        textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: height)
    }

    private func fittingHeight() -> CGFloat {
        guard bounds.width > 1 else {
            return Self.minimumHeight(for: currentFont)
        }
        let availableWidth = max(bounds.width, 1)
        return fittingHeight(for: availableWidth)
    }

    private func updatePlaceholderVisibility() {
        placeholderField.isHidden = !textView.string.isEmpty
    }
}

private struct FeedInlineTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    let placeholder: String
    let isEnabled: Bool
    let font: NSFont
    let onFocus: () -> Void
    let onBlur: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FeedInlineTextField
        var isProgrammaticMutation = false
        weak var view: FeedInlineTextEditorView?
        var pendingFocusRequest: Bool?

        init(parent: FeedInlineTextField) {
            self.parent = parent
        }

        func activateField() {
#if DEBUG
            dlog("feed.editor.activateField")
#endif
            parent.onFocus()
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func blurField() {
            pendingFocusRequest = nil
            if parent.isFocused {
                parent.isFocused = false
            }
            guard let view, let window = view.window, window.firstResponder === view.textView else {
                return
            }
#if DEBUG
            dlog("feed.editor.blurField frBefore=\(feedDebugResponderSummary(window.firstResponder))")
#endif
            Task { @MainActor in
                if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                    mode: .feed,
                    focusFirstItem: false,
                    preferredWindow: window
                ) != true {
                    window.makeFirstResponder(nil)
                }
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            activateField()
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            view?.refreshMetrics()
        }

        func textDidEndEditing(_ notification: Notification) {
            if !isProgrammaticMutation, let textView = notification.object as? NSTextView {
                parent.text = textView.string
            }
            if parent.isFocused {
                parent.isFocused = false
            }
            guard let window = view?.window else {
                parent.onBlur()
                return
            }
            let responder = window.firstResponder
            if !(responder is FeedKeyboardFocusView) && !(responder is FeedInlineNativeTextView) {
                parent.onBlur()
            }
        }

    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FeedInlineTextEditorView {
        let view = FeedInlineTextEditorView(frame: .zero)
        view.textView.delegate = context.coordinator
        view.textView.string = text
        view.textView.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateField()
        }
        view.textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.blurField()
        }
        configure(view)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: FeedInlineTextEditorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.view = nsView
        nsView.textView.onActivate = { [weak coordinator = context.coordinator] in
            coordinator?.activateField()
        }
        nsView.textView.onEscape = { [weak coordinator = context.coordinator] in
            coordinator?.blurField()
        }
        configure(nsView)

        if nsView.textView.string != text, !nsView.textView.hasMarkedText() {
            context.coordinator.isProgrammaticMutation = true
            nsView.textView.string = text
            context.coordinator.isProgrammaticMutation = false
            nsView.refreshMetrics()
        }

        guard let window = nsView.window else { return }
        let firstResponder = window.firstResponder
        let isFirstResponder = firstResponder === nsView.textView

        if isFocused, isEnabled, !isFirstResponder, context.coordinator.pendingFocusRequest != true {
            context.coordinator.pendingFocusRequest = true
            DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                coordinator?.pendingFocusRequest = nil
                guard let coordinator, coordinator.parent.isFocused, coordinator.parent.isEnabled else { return }
                nsView?.focusIfNeeded()
            }
        } else if (!isFocused || !isEnabled), isFirstResponder, context.coordinator.pendingFocusRequest != false {
            context.coordinator.pendingFocusRequest = false
            Task { @MainActor [weak nsView, weak coordinator = context.coordinator] in
                coordinator?.pendingFocusRequest = nil
                guard let nsView, let window = nsView.window else { return }
                let stillFocused = window.firstResponder === nsView.textView
                guard stillFocused else { return }
                if AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                    mode: .feed,
                    focusFirstItem: false,
                    preferredWindow: window
                ) != true {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }

    private func configure(_ view: FeedInlineTextEditorView) {
        view.placeholder = placeholder
        view.apply(font: font, isEnabled: isEnabled)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: FeedInlineTextEditorView,
        context: Context
    ) -> CGSize? {
        nil
    }

    static func dismantleNSView(_ nsView: FeedInlineTextEditorView, coordinator: Coordinator) {
        nsView.textView.delegate = nil
        nsView.textView.onActivate = nil
        nsView.textView.onEscape = nil
    }
}

private struct FeedHoverCursorModifier: ViewModifier {
    let enabled: Bool
    let cursor: NSCursor

    @State private var cursorPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering, enabled {
                    pushIfNeeded()
                } else {
                    popIfNeeded()
                }
            }
            .onDisappear {
                popIfNeeded()
            }
    }

    private func pushIfNeeded() {
        guard !cursorPushed else { return }
        cursor.push()
        cursorPushed = true
    }

    private func popIfNeeded() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}

private extension View {
    func feedIBeamCursorOnHover(enabled: Bool) -> some View {
        modifier(FeedHoverCursorModifier(enabled: enabled, cursor: .iBeam))
    }
}

/// Minimal wrapping HStack that flows its children into multiple rows.
private struct WrapHStack<Content: View>: View {
    let spacing: CGFloat
    let content: () -> Content

    init(spacing: CGFloat = 4, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        FlowLayout(spacing: spacing) {
            content()
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                totalHeight += currentRowHeight + spacing
                totalWidth = max(totalWidth, currentX - spacing)
                currentX = 0
                currentRowHeight = 0
            }
            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        totalHeight += currentRowHeight
        totalWidth = max(totalWidth, currentX - spacing)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Renders a Stop event (Claude finished a turn and is waiting for
/// the next user prompt). Shows a text field + Send button that
/// types the reply into the agent's terminal surface and presses
/// Return — so the user can reply without switching focus.
private struct StopActionArea: View {
    let workstreamId: String
    let isRowSelected: Bool
    let onFocusRow: () -> Void
    let onBlurRow: () -> Void
    let onSend: (String) -> Void

    @State private var reply: String = ""
    @FocusState private var replyFocused: Bool

    private var trimmed: String {
        reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSend: Bool { !trimmed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(String(localized: "feed.stop.label", defaultValue: "Claude finished — reply to continue"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            TextField(
                String(localized: "feed.stop.placeholder", defaultValue: "Reply to Claude…"),
                text: $reply,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($replyFocused)
            .onChange(of: replyFocused) { _, focused in
                if focused {
                    onFocusRow()
                } else {
                    onBlurRow()
                }
            }
            .lineLimit(1...5)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(canSend ? 0.25 : 0.10), lineWidth: 1)
            )
            .onSubmit {
                if canSend {
                    onSend(trimmed)
                    reply = ""
                }
            }
            FeedButton(
                label: String(localized: "feed.stop.send", defaultValue: "Send to Claude"),
                leadingIcon: "arrow.up.circle.fill",
                kind: canSend ? .primary : .soft,
                size: .medium,
                fullWidth: true,
                dimmed: !canSend
            ) {
                onFocusRow()
                onSend(trimmed)
                reply = ""
            }
        }
        .onChange(of: isRowSelected) { _, selected in
            if !selected {
                replyFocused = false
            }
        }
    }
}

private struct TelemetryActionArea: View {
    let snapshot: FeedItemSnapshot

    var body: some View {
        if case .todos(let todos) = snapshot.payload {
            TodoListBody(todos: todos)
        } else if case .assistantMessage(let text) = snapshot.payload,
                  snapshot.source == .claude {
            FeedMarkdownInlineText(
                text: text,
                fontSize: 11,
                foregroundColor: .secondary.opacity(0.85)
            )
            .lineLimit(3)
            .truncationMode(.tail)
        } else if !summary.isEmpty {
            Text(summary)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(3)
                .truncationMode(.tail)
        }
    }

    private var summary: String {
        switch snapshot.payload {
        case .toolUse(let name, let json):
            return "\(name) \(json)"
        case .toolResult(let name, let json, let err):
            let status = err
                ? String(localized: "feed.telemetry.error", defaultValue: "error")
                : String(localized: "feed.telemetry.ok", defaultValue: "ok")
            return "\(name) \(status) \(json)"
        case .userPrompt(let text), .assistantMessage(let text):
            return text
        case .sessionStart:
            return String(localized: "feed.telemetry.sessionStart", defaultValue: "session start")
        case .sessionEnd:
            return String(localized: "feed.telemetry.sessionEnd", defaultValue: "session end")
        case .stop(let reason):
            let label = String(localized: "feed.telemetry.stop", defaultValue: "stop")
            guard let reason, !reason.isEmpty else { return label }
            return "\(label) \(reason)"
        default:
            return ""
        }
    }
}

private struct TodoListBody: View {
    let todos: [WorkstreamTaskTodo]

    @State private var expanded = false

    private var done: [WorkstreamTaskTodo] { todos.filter { $0.state == .completed } }
    private var inProgress: [WorkstreamTaskTodo] { todos.filter { $0.state == .inProgress } }
    private var pending: [WorkstreamTaskTodo] { todos.filter { $0.state == .pending } }

    private var visibleDone: [WorkstreamTaskTodo] {
        expanded ? done : Array(done.prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(String(localized: "feed.todos.title", defaultValue: "Tasks"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))
                Text(summaryLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(inProgress, id: \.id) { row($0) }
                ForEach(pending, id: \.id) { row($0) }
                ForEach(visibleDone, id: \.id) { row($0) }
                if done.count > visibleDone.count {
                    Button {
                        expanded.toggle()
                    } label: {
                        Text(String(
                            localized: "feed.todos.moreCompleted",
                            defaultValue: "... +\(done.count - visibleDone.count) completed"
                        ))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                            .padding(.leading, 22)
                    }
                    .buttonStyle(.plain)
                }
                if expanded && done.count > 2 {
                    Button { expanded = false } label: {
                        Text(String(localized: "feed.todos.collapse", defaultValue: "Collapse"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                            .padding(.leading, 22)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var summaryLabel: String {
        let d = done.count, ip = inProgress.count, p = pending.count
        var parts: [String] = []
        if d > 0 {
            parts.append(String(localized: "feed.todos.summary.done", defaultValue: "\(d) done"))
        }
        if ip > 0 {
            parts.append(String(localized: "feed.todos.summary.inProgress", defaultValue: "\(ip) in progress"))
        }
        if p > 0 {
            parts.append(String(localized: "feed.todos.summary.open", defaultValue: "\(p) open"))
        }
        return "(" + parts.joined(separator: ", ") + ")"
    }

    @ViewBuilder
    private func row(_ todo: WorkstreamTaskTodo) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol(for: todo.state))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(color(for: todo.state))
                .frame(width: 14, height: 14)
            Text(todo.content)
                .font(.system(size: 12))
                .foregroundColor(todo.state == .completed
                    ? .secondary.opacity(0.7)
                    : .primary.opacity(0.9))
                .strikethrough(todo.state == .completed, color: .secondary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func symbol(for state: WorkstreamTaskTodo.State) -> String {
        switch state {
        case .completed: return "checkmark.square.fill"
        case .inProgress: return "circle.fill"
        case .pending: return "square"
        }
    }

    private func color(for state: WorkstreamTaskTodo.State) -> Color {
        switch state {
        case .completed: return .secondary.opacity(0.7)
        case .inProgress: return .blue
        case .pending: return .secondary
        }
    }
}

/// Dashed separator between pending items and resolved ones.
private struct ResolvedDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            line
            Text(String(localized: "feed.divider.resolved", defaultValue: "Resolved"))
                .font(.system(size: 10, weight: .medium))
                .tracking(0.5)
                .foregroundColor(.secondary.opacity(0.7))
            line
        }
        .padding(.vertical, 2)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}

// MARK: - Kind → SF Symbol

private extension WorkstreamKind {
    var symbolName: String {
        switch self {
        case .permissionRequest: return "lock.shield"
        case .exitPlan: return "list.bullet.rectangle"
        case .question: return "questionmark.circle"
        case .toolUse, .toolResult: return "terminal"
        case .userPrompt: return "person"
        case .assistantMessage: return "sparkles"
        case .sessionStart, .sessionEnd: return "play.circle"
        case .stop: return "stop.circle"
        case .todos: return "checklist"
        }
    }
}
