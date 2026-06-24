import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxAppKitSupportUI
import CmuxFeedUI
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

        /// The pure projection discriminant for this filter, used to drive
        /// `FeedItemProjection`. The package owns the snapshot transforms; this
        /// app-side type owns only the localized label and SF Symbol.
        var projectionMode: FeedFilterMode {
            switch self {
            case .actionable: return .actionable
            case .activity: return .activity
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
#if DEBUG
        // Install the app-side Feed Button Style debug settings into the
        // environment so every descendant package `FeedButton` can render the
        // debug treatment chosen in the Feed Button Style window.
        .feedButtonDebugStyleProvider(FeedButtonDebugSettings.styleProvider)
#endif
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

    @State private var focusSnapshot = FeedFocusSnapshot()
    @State private var scrollRequest: FeedScrollRequest?
    @State private var scrollRequestSequence = 0
    @State private var stopDrafts: [UUID: FeedStopDraft] = [:]

    private var projection: FeedItemProjection {
        FeedItemProjection(filter: filter.projectionMode)
    }

    var body: some View {
        let projection = self.projection
        let snapshots = projection.visibleSnapshots(items)
        let activityGroups = filter == .activity ? projection.activitySnapshotGroups(snapshots) : nil
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
        activityGroups: FeedItemProjection.ActivitySnapshotGroups?,
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
                groups: activityGroups ?? projection.activitySnapshotGroups(snapshots),
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
        groups: FeedItemProjection.ActivitySnapshotGroups,
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
            },
            moveFocusToFeedHost: FeedPanelView.moveFeedKeyboardFocusToHost(in:),
            responderRetainsFeedFocus: FeedPanelView.responderRetainsFeedFocus(_:)
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
            FeedInlineTextField.blurActiveEditor()
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
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
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
//
// `FeedItemSnapshot` (the immutable `WorkstreamItem` projection handed to row
// views), `FeedRowActions` (the closure bundle), `FeedItemRow`, and
// `FeedRowSurface` now live in the `CmuxFeedUI`/`CMUXAgentLaunch` packages.
// The app keeps only the live-coordinator binding for `FeedRowActions`.

extension FeedRowActions {
    /// Closure bundle bound to `FeedCoordinator`, the app-side feed owner.
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

extension FeedPanelView {
    /// Focus seam for `FeedInlineTextField` (used by ``QuestionActionArea`` and
    /// ``StopActionArea``): ask the app to move keyboard focus to the Feed
    /// right-sidebar host for `window`, returning whether it did. The app stays
    /// the only caller of `focusRightSidebarInActiveMainWindow`.
    @MainActor
    static func moveFeedKeyboardFocusToHost(in window: NSWindow) -> Bool {
        AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
            mode: .feed,
            focusFirstItem: false,
            preferredWindow: window
        ) == true
    }

    /// Focus seam for `FeedInlineTextField` (used by ``QuestionActionArea`` and
    /// ``StopActionArea``): report whether a window's new first responder still
    /// belongs to the Feed focus domain (the Feed keyboard host or another
    /// inline editor), so end-of-editing does not fire `onBlur` while focus
    /// merely hops within the Feed sidebar. Inline editors are matched via the
    /// `FeedKeyboardFocusResponder` marker, which `FeedInlineNativeTextView`
    /// adopts inside `CmuxFeedUI`.
    nonisolated static func responderRetainsFeedFocus(_ responder: NSResponder) -> Bool {
        responder is FeedKeyboardFocusView || responder is FeedKeyboardFocusResponder
    }
}

