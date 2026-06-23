public import SwiftUI
public import Combine
public import CmuxSidebar
public import UniformTypeIdentifiers
import CmuxAppKitSupportUI
import CmuxFoundation

/// One workspace row in the vertical sidebar, lifted from the app target's
/// `ContentView`. It composes the package row content, background, drop
/// indicator, hover tracker, height probe, shortcut-hint overlay, drag/drop
/// delegates, and the workspace context menu.
///
/// Typing-latency contract (see CLAUDE.md): the row keeps its `Equatable`
/// conformance and is mounted with `.equatable()` so body re-evaluation is
/// skipped while the user types. It holds no `@ObservedObject`/`@EnvironmentObject`
/// store (the workspace identity is a plain `tabId`, not a `Tab` reference, since
/// `Tab` lives in the app target), reading only precomputed value snapshots and
/// closure action bundles. Reorder, cross-window move, and color writes route
/// through ``WorkspaceTabRouting`` via the injected drop delegates and the
/// context-menu action closures. The host keeps a thin adapter that builds the
/// snapshots/closures from its `TabManager`/`TerminalNotificationStore`.
public struct TabItemView: View, Equatable {
    // Closures, Bindings, and object references are excluded from ==
    // because they're recreated every parent eval but don't affect rendering.
    public nonisolated static func == (lhs: TabItemView, rhs: TabItemView) -> Bool {
        lhs.tabId == rhs.tabId &&
        lhs.index == rhs.index &&
        lhs.isActive == rhs.isActive &&
        lhs.workspaceShortcutDigit == rhs.workspaceShortcutDigit &&
        lhs.workspaceShortcutModifierSymbol == rhs.workspaceShortcutModifierSymbol &&
        lhs.canCloseWorkspace == rhs.canCloseWorkspace &&
        lhs.accessibilityWorkspaceCount == rhs.accessibilityWorkspaceCount &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.hasMemoryWarning == rhs.hasMemoryWarning &&
        lhs.latestNotificationText == rhs.latestNotificationText &&
        lhs.rowSpacing == rhs.rowSpacing &&
        lhs.showsModifierShortcutHints == rhs.showsModifierShortcutHints &&
        lhs.contextMenuWorkspaceIds == rhs.contextMenuWorkspaceIds &&
        lhs.remoteContextMenuWorkspaceIds == rhs.remoteContextMenuWorkspaceIds &&
        lhs.allRemoteContextMenuTargetsConnecting == rhs.allRemoteContextMenuTargetsConnecting &&
        lhs.allRemoteContextMenuTargetsDisconnected == rhs.allRemoteContextMenuTargetsDisconnected &&
        lhs.contextMenuPinState == rhs.contextMenuPinState &&
        lhs.workspaceGroupMenuSnapshot == rhs.workspaceGroupMenuSnapshot &&
        lhs.isBeingDragged == rhs.isBeingDragged &&
        lhs.topDropIndicatorVisible == rhs.topDropIndicatorVisible &&
        lhs.settings == rhs.settings
    }

    @Environment(\.colorScheme) private var colorScheme

    // Identity + value snapshots (everything in `==`).
    let tabId: UUID
    let index: Int
    let isActive: Bool
    let workspaceShortcutDigit: Int?
    let workspaceShortcutModifierSymbol: String
    let canCloseWorkspace: Bool
    let accessibilityWorkspaceCount: Int
    let unreadCount: Int
    /// True when any pane in this workspace is over the runaway-memory
    /// threshold. Precomputed snapshot value (snapshot-boundary rule); drives
    /// the orange warning badge alongside the unread badge.
    let hasMemoryWarning: Bool
    let latestNotificationText: String?
    let rowSpacing: CGFloat
    let showsModifierShortcutHints: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let contextMenuWorkspaceIds: [UUID]
    let remoteContextMenuWorkspaceIds: [UUID]
    let allRemoteContextMenuTargetsConnecting: Bool
    let allRemoteContextMenuTargetsDisconnected: Bool
    let contextMenuPinState: TabItemContextMenuPinState?
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    let settings: TabItemSettingsSnapshot

    // Workspace-observation publishers (value-typed; the row redraws its
    // snapshot when the host workspace emits a sidebar invalidation).
    let immediateObservationPublisher: AnyPublisher<Void, Never>
    let observationPublisher: AnyPublisher<Void, Never>
    let workspaceObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride

    // DEBUG-only render log for the lifted description text view; nil in release.
    let descriptionDebugLog: ((_ phase: String, _ markdown: String) -> Void)?

    // App-resolved appearance (depends on colorScheme), color math stays app-side.
    let makeStyle: @MainActor (ColorScheme) -> TabItemRowStyle
    // App-resolved workspace snapshot (reads the app `Tab`), recomputed on demand.
    let makeWorkspaceSnapshot: @MainActor () -> SidebarWorkspaceSnapshotBuilder.Snapshot
    // App-resolved context-menu data + actions, built once per body eval.
    let makeContextMenuData: @MainActor (SidebarWorkspaceSnapshotBuilder.Snapshot) -> SidebarWorkspaceContextMenuData
    let makeContextMenuActions: @MainActor (
        SidebarWorkspaceSnapshotBuilder.Snapshot,
        @escaping (TabItemFinderDirectoryOpenRequest) -> Void
    ) -> SidebarWorkspaceContextMenuActions

    // Action closures the row triggers (all app-coupled mutations).
    let onSelect: () -> Void
    let onCloseWorkspace: (_ method: String) -> Void
    let onReconnect: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onContextMenuAppear: () -> Void
    let onContextMenuDisappear: () -> Void
    let onOpenPullRequest: (URL) -> Void
    let onOpenPort: (Int) -> Void
    let pullRequestStatusLabel: (SidebarPullRequestStatus) -> String
    // Port label/tooltip text resolved app-side (`SidebarPortDisplayText` lives
    // in the app target).
    let portLabel: (Int) -> String
    let portTooltip: (Int) -> String

    // Drag/drop wiring (package-typed delegates; the app supplies the router).
    let onDragStart: () -> NSItemProvider
    let tabDropDelegateFactory: (CGFloat) -> SidebarTabDropDelegate
    let bonsplitDropDelegate: SidebarBonsplitTabDropDelegate
    /// Content types for the bonsplit-tab drop; the `BonsplitTabDragPayload`
    /// UTType lives in the app target, so the host passes its `dropContentTypes`.
    let bonsplitDropContentTypes: [UTType]

    @State private var workspaceSnapshotStorage: SidebarWorkspaceSnapshotBuilder.Snapshot?
    @State private var contextMenuState = SidebarTabItemContextMenuModel()
    @State private var rowInteractionState = SidebarWorkspaceRowInteractionState()
    @State private var rowHeight: CGFloat = 1
    @State private var workspaceFinderDirectoryOpenRequest: TabItemFinderDirectoryOpenRequest?

    private static let maxWrappedTitleLines = 8
    private static let maxDisplayedTitleCharacters = 2048

    public init(
        tabId: UUID,
        index: Int,
        isActive: Bool,
        workspaceShortcutDigit: Int?,
        workspaceShortcutModifierSymbol: String,
        canCloseWorkspace: Bool,
        accessibilityWorkspaceCount: Int,
        unreadCount: Int,
        hasMemoryWarning: Bool,
        latestNotificationText: String?,
        rowSpacing: CGFloat,
        showsModifierShortcutHints: Bool,
        isBeingDragged: Bool,
        topDropIndicatorVisible: Bool,
        contextMenuWorkspaceIds: [UUID],
        remoteContextMenuWorkspaceIds: [UUID],
        allRemoteContextMenuTargetsConnecting: Bool,
        allRemoteContextMenuTargetsDisconnected: Bool,
        contextMenuPinState: TabItemContextMenuPinState?,
        workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot,
        settings: TabItemSettingsSnapshot,
        immediateObservationPublisher: AnyPublisher<Void, Never>,
        observationPublisher: AnyPublisher<Void, Never>,
        workspaceObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride,
        descriptionDebugLog: ((_ phase: String, _ markdown: String) -> Void)?,
        makeStyle: @escaping @MainActor (ColorScheme) -> TabItemRowStyle,
        makeWorkspaceSnapshot: @escaping @MainActor () -> SidebarWorkspaceSnapshotBuilder.Snapshot,
        makeContextMenuData: @escaping @MainActor (SidebarWorkspaceSnapshotBuilder.Snapshot) -> SidebarWorkspaceContextMenuData,
        makeContextMenuActions: @escaping @MainActor (
            SidebarWorkspaceSnapshotBuilder.Snapshot,
            @escaping (TabItemFinderDirectoryOpenRequest) -> Void
        ) -> SidebarWorkspaceContextMenuActions,
        onSelect: @escaping () -> Void,
        onCloseWorkspace: @escaping (_ method: String) -> Void,
        onReconnect: @escaping () -> Void,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void,
        onContextMenuAppear: @escaping () -> Void,
        onContextMenuDisappear: @escaping () -> Void,
        onOpenPullRequest: @escaping (URL) -> Void,
        onOpenPort: @escaping (Int) -> Void,
        pullRequestStatusLabel: @escaping (SidebarPullRequestStatus) -> String,
        portLabel: @escaping (Int) -> String,
        portTooltip: @escaping (Int) -> String,
        onDragStart: @escaping () -> NSItemProvider,
        tabDropDelegateFactory: @escaping (CGFloat) -> SidebarTabDropDelegate,
        bonsplitDropDelegate: SidebarBonsplitTabDropDelegate,
        bonsplitDropContentTypes: [UTType]
    ) {
        self.tabId = tabId
        self.index = index
        self.isActive = isActive
        self.workspaceShortcutDigit = workspaceShortcutDigit
        self.workspaceShortcutModifierSymbol = workspaceShortcutModifierSymbol
        self.canCloseWorkspace = canCloseWorkspace
        self.accessibilityWorkspaceCount = accessibilityWorkspaceCount
        self.unreadCount = unreadCount
        self.hasMemoryWarning = hasMemoryWarning
        self.latestNotificationText = latestNotificationText
        self.rowSpacing = rowSpacing
        self.showsModifierShortcutHints = showsModifierShortcutHints
        self.isBeingDragged = isBeingDragged
        self.topDropIndicatorVisible = topDropIndicatorVisible
        self.contextMenuWorkspaceIds = contextMenuWorkspaceIds
        self.remoteContextMenuWorkspaceIds = remoteContextMenuWorkspaceIds
        self.allRemoteContextMenuTargetsConnecting = allRemoteContextMenuTargetsConnecting
        self.allRemoteContextMenuTargetsDisconnected = allRemoteContextMenuTargetsDisconnected
        self.contextMenuPinState = contextMenuPinState
        self.workspaceGroupMenuSnapshot = workspaceGroupMenuSnapshot
        self.settings = settings
        self.immediateObservationPublisher = immediateObservationPublisher
        self.observationPublisher = observationPublisher
        self.workspaceObservationCoalesceInterval = workspaceObservationCoalesceInterval
        self.descriptionDebugLog = descriptionDebugLog
        self.makeStyle = makeStyle
        self.makeWorkspaceSnapshot = makeWorkspaceSnapshot
        self.makeContextMenuData = makeContextMenuData
        self.makeContextMenuActions = makeContextMenuActions
        self.onSelect = onSelect
        self.onCloseWorkspace = onCloseWorkspace
        self.onReconnect = onReconnect
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onContextMenuAppear = onContextMenuAppear
        self.onContextMenuDisappear = onContextMenuDisappear
        self.onOpenPullRequest = onOpenPullRequest
        self.onOpenPort = onOpenPort
        self.pullRequestStatusLabel = pullRequestStatusLabel
        self.portLabel = portLabel
        self.portTooltip = portTooltip
        self.onDragStart = onDragStart
        self.tabDropDelegateFactory = tabDropDelegateFactory
        self.bonsplitDropDelegate = bonsplitDropDelegate
        self.bonsplitDropContentTypes = bonsplitDropContentTypes
    }

    private var visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility {
        settings.visibleAuxiliaryDetails
    }

    private var fontScale: CGFloat {
        settings.sidebarFontScale
    }

    private func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
        baseSize * fontScale
    }

    private var workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot {
        let next = makeWorkspaceSnapshot()
        if let workspaceSnapshotStorage,
           workspaceSnapshotStorage.presentationKey == next.presentationKey {
            return workspaceSnapshotStorage
        }
        return next
    }

    private var workspaceShortcutLabel: String? {
        guard let workspaceShortcutDigit else { return nil }
        return "\(workspaceShortcutModifierSymbol)\(workspaceShortcutDigit)"
    }

    private var showsWorkspaceShortcutHint: Bool {
        (showsModifierShortcutHints || settings.alwaysShowShortcutHints) && workspaceShortcutLabel != nil
    }

    private var showCloseButton: Bool {
        rowInteractionState.shouldShowCloseButton(
            canCloseWorkspace: canCloseWorkspace,
            shortcutHintModeActive: showsModifierShortcutHints || settings.alwaysShowShortcutHints
        )
    }

    private var accessibilityTitle: String {
        String(
            localized: "accessibility.workspacePosition",
            defaultValue: "\(workspaceSnapshot.title), workspace \(index + 1) of \(accessibilityWorkspaceCount)",
            bundle: .main
        )
    }

    private var accessibilityHintText: String {
        String(
            localized: "sidebar.workspace.accessibilityHint",
            defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions.",
            bundle: .main
        )
    }

    private var moveUpActionText: String {
        String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up", bundle: .main)
    }

    private var moveDownActionText: String {
        String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down", bundle: .main)
    }

    /// The inner row content (header, description, subtitle, remote section,
    /// auxiliary details), extracted from `body` so the large argument list
    /// type-checks separately from the row's modifier chain (per the
    /// per-body-struct rule that keeps `TabItemView` under the type-check
    /// timeout). Returns the concrete package view.
    private func rowContent(
        style: TabItemRowStyle,
        workspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot
    ) -> SidebarWorkspaceRowContent {
        let protectedWorkspaceTooltip = String(
            localized: "sidebar.pinnedWorkspaceProtected.tooltip",
            defaultValue: "Pinned workspace. Closing requires confirmation.",
            bundle: .main
        )
        let closeWorkspaceTooltip = String(
            localized: "sidebar.closeWorkspace.tooltip",
            defaultValue: "Close Workspace",
            bundle: .main
        )
        let closeButtonTooltip = workspaceSnapshot.isPinned
            ? protectedWorkspaceTooltip
            : closeWorkspaceTooltip
        let latestNotificationSubtitle = latestNotificationText
        let conversationMessageSubtitle: String? = (!settings.hidesAllDetails && settings.iMessageModeEnabled)
            ? workspaceSnapshot.latestConversationMessage?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            : nil
        let effectiveSubtitle = latestNotificationSubtitle ?? conversationMessageSubtitle
        let detailVisibility = visibleAuxiliaryDetails
        let titleLineLimit = settings.wrapsWorkspaceTitles ? Self.maxWrappedTitleLines : 1
        let displayedTitle = workspaceSnapshot.title.sidebarBoundedDisplayString(
            maxDisplayedLines: titleLineLimit,
            maxDisplayedCharacters: Self.maxDisplayedTitleCharacters
        )
        let scaledUnreadBadgeSize = 16 * fontScale
        let scaledCloseButtonHitSize = max(16, 16 * fontScale)
        let scaledCloseButtonWidth = max(
            SidebarTrailingAccessoryWidthPolicy().closeButtonWidth,
            scaledCloseButtonHitSize
        )
        let memoryWarningTooltip = String(
            localized: "sidebar.memoryWarning.tooltip",
            defaultValue: "A pane in this workspace is using a lot of memory",
            bundle: .main
        )
        let memoryWarningAccessibilityLabel = String(
            localized: "sidebar.memoryWarning.accessibilityLabel",
            defaultValue: "High memory warning",
            bundle: .main
        )

        return SidebarWorkspaceRowContent(
            snapshot: workspaceSnapshot,
            detailVisibility: detailVisibility,
            isActive: style.usesInvertedActiveForeground,
            unreadCount: unreadCount,
            unreadBadgeFillColor: style.unreadBadgeFillColor,
            unreadBadgeTextColor: style.unreadBadgeTextColor,
            unreadBadgeDiameter: scaledUnreadBadgeSize,
            hasMemoryWarning: hasMemoryWarning,
            memoryWarningTooltip: memoryWarningTooltip,
            memoryWarningAccessibilityLabel: memoryWarningAccessibilityLabel,
            pinnedTooltip: protectedWorkspaceTooltip,
            displayedTitle: displayedTitle,
            titleColor: style.primaryTextColor,
            titleFontWeight: style.titleFontWeight,
            titleLineLimit: titleLineLimit,
            pinIconColor: style.activeSecondaryColor(0.8),
            closeButtonColor: style.activeSecondaryColor(0.7),
            showsCloseButton: canCloseWorkspace,
            closeButtonVisible: showCloseButton,
            closeButtonWidth: scaledCloseButtonWidth,
            closeButtonHitSize: scaledCloseButtonHitSize,
            closeButtonTooltip: closeButtonTooltip,
            onClose: { onCloseWorkspace("button") },
            descriptionActiveForegroundColor: style.activeSecondaryColor(0.84),
            descriptionDebugLog: descriptionDebugLog,
            subtitle: effectiveSubtitle,
            subtitleColor: style.activeSecondaryColor(0.8),
            showsRemoteSection: !settings.hidesAllDetails && settings.showsSSH,
            remoteHostColor: style.activeSecondaryColor(0.8),
            remoteStatusColor: style.activeSecondaryColor(0.58),
            remoteReconnectColor: style.activeSecondaryColor(0.9),
            remoteTopPadding: latestNotificationText == nil ? 1 : 2,
            onReconnect: { onReconnect() },
            activeSecondaryColor: { style.activeSecondaryColor($0) },
            progressTrackColor: style.progressTrackColor,
            progressFillColor: style.progressFillColor,
            branchSecondaryColor: style.activeSecondaryColor(0.75),
            branchIconColor: style.activeSecondaryColor(0.6),
            usesVerticalBranchLayout: settings.usesVerticalBranchLayout,
            stacksBranchAndDirectory: settings.stacksBranchAndDirectory,
            showsGitBranchIcon: settings.showsGitBranchIcon,
            pullRequestForegroundColor: style.pullRequestForegroundColor,
            makesPullRequestsClickable: settings.makesPullRequestsClickable,
            fontScale: fontScale,
            onFocus: { onSelect() },
            pullRequestStatusLabel: { pullRequestStatusLabel($0) },
            pullRequestOpenTooltip: { title in
                String(localized: "sidebar.pullRequest.openTooltip", defaultValue: "Open \(title)", bundle: .main)
            },
            onOpenPullRequest: { onOpenPullRequest($0) },
            portLabel: { portLabel($0) },
            portTooltip: { portTooltip($0) },
            onOpenPort: { onOpenPort($0) }
        )
    }

    public var body: some View {
        let style = makeStyle(colorScheme)
        let workspaceSnapshot = self.workspaceSnapshot

        rowContent(style: style, workspaceSnapshot: workspaceSnapshot)
        // No implicit .animation(value:) on agent-mutable fields: animating a
        // row-height change interpolates the LazyVStack's measured height over
        // every frame of the 0.2s curve, and with dozens of agent sessions some
        // row is always animating, so the sidebar-wide layout re-runs at display
        // refresh rate (#5764 / #5845). Lazy rows must be height-stable after
        // they appear; content changes now apply in one discrete layout pass.
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            SidebarWorkspaceRowBackground(
                fillColor: style.backgroundColor,
                borderColor: style.borderColor,
                borderLineWidth: style.borderLineWidth,
                showsLeadingRail: style.showsLeadingRail,
                railColor: style.railColor
            )
        )
        .tabItemShortcutHintOverlay(
            text: showsWorkspaceShortcutHint ? workspaceShortcutLabel : nil,
            emphasis: style.shortcutHintEmphasis,
            offsetX: settings.sidebarShortcutHintXOffset,
            offsetY: settings.sidebarShortcutHintYOffset,
            fontSize: scaledFontSize(10)
        )
        .tabItemShortcutHintVisibilityAnimation(value: showsWorkspaceShortcutHint)
        .padding(.horizontal, 6)
        .background { SidebarRowHeightProbe { rowHeight = $0 } }
        .contentShape(Rectangle())
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay {
            SidebarWorkspaceRowHoverTracker(
                onPointerHoverChanged: { hovering in
                    rowInteractionState.setPointerHovering(hovering)
                },
                onMenuTrackingChanged: { tracking in
                    if tracking {
                        rowInteractionState.contextMenuTrackingDidBegin()
                    } else {
                        rowInteractionState.contextMenuTrackingDidEnd()
                    }
                }
            )
        }
        .overlay {
            MiddleClickCapture {
                onCloseWorkspace("middleClick")
            }
        }
        .overlay(alignment: .top) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: topDropIndicatorVisible,
                isFirstRow: index == 0,
                rowSpacing: rowSpacing,
                accent: style.accentColor
            )
        }
        .onAppear {
            refreshWorkspaceSnapshot(force: true)
        }
        .task(id: workspaceFinderDirectoryOpenRequest) {
            guard let request = workspaceFinderDirectoryOpenRequest else { return }
            await TabItemFinderDirectoryOpener.openInFinder(request.directoryURL)
            guard !Task.isCancelled, workspaceFinderDirectoryOpenRequest == request else { return }
            workspaceFinderDirectoryOpenRequest = nil
        }
        .onReceive(immediateObservationPublisher.receive(on: RunLoop.main)) { _ in
            refreshWorkspaceSnapshot()
        }
        .onReceive(
            observationPublisher
                .receive(on: RunLoop.main)
                // Prompt-time sidebar telemetry can arrive as a short burst
                // (pwd, branch, PR, shell state). Coalesce that burst so the
                // row redraws once with the settled state instead of blinking.
                .debounce(for: workspaceObservationCoalesceInterval, scheduler: RunLoop.main)
        ) { _ in
            refreshWorkspaceSnapshot()
        }
        .onChange(of: settings) { _ in
            refreshWorkspaceSnapshot(force: true)
        }
        .onDrag(onDragStart)
        .internalOnlyTabDrag()
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: tabDropDelegateFactory(rowHeight))
        .onDrop(of: bonsplitDropContentTypes, delegate: bonsplitDropDelegate)
        .onTapGesture {
            onSelect()
        }
        .safeHelp(workspaceSnapshot.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityHint(Text(accessibilityHintText))
        .accessibilityAction(named: Text(moveUpActionText)) {
            onMoveUp()
        }
        .accessibilityAction(named: Text(moveDownActionText)) {
            onMoveDown()
        }
        .contextMenu {
            SidebarWorkspaceContextMenu(
                data: makeContextMenuData(workspaceSnapshot),
                actions: makeContextMenuActions(workspaceSnapshot) { request in
                    workspaceFinderDirectoryOpenRequest = request
                }
            )
            .onAppear {
                rowInteractionState.contextMenuDidAppear()
                contextMenuState.hasDeferredWorkspaceObservationInvalidation = false
                contextMenuState.pendingWorkspaceSnapshot = nil
                onContextMenuAppear()
            }
            .onDisappear {
                rowInteractionState.contextMenuDidDisappear()
                onContextMenuDisappear()
                flushDeferredWorkspaceObservationInvalidation()
            }
        }
    }

    private func refreshWorkspaceSnapshot(force: Bool = false) {
        let nextSnapshot = makeWorkspaceSnapshot()
        let decision = SidebarWorkspaceSnapshotRefreshPolicy.decision(
            current: workspaceSnapshotStorage,
            next: nextSnapshot,
            force: force,
            contextMenuVisible: rowInteractionState.contextMenuVisible
        )

        if workspaceSnapshotStorage != decision.workspaceSnapshotStorage {
            workspaceSnapshotStorage = decision.workspaceSnapshotStorage
        }
        if contextMenuState.pendingWorkspaceSnapshot != decision.pendingWorkspaceSnapshot {
            contextMenuState.pendingWorkspaceSnapshot = decision.pendingWorkspaceSnapshot
        }
        if contextMenuState.hasDeferredWorkspaceObservationInvalidation != decision.hasDeferredWorkspaceObservationInvalidation {
            contextMenuState.hasDeferredWorkspaceObservationInvalidation = decision.hasDeferredWorkspaceObservationInvalidation
        }
    }

    private func flushDeferredWorkspaceObservationInvalidation() {
        guard contextMenuState.hasDeferredWorkspaceObservationInvalidation else { return }
        contextMenuState.hasDeferredWorkspaceObservationInvalidation = false
        if let pendingSnapshot = contextMenuState.pendingWorkspaceSnapshot {
            workspaceSnapshotStorage = pendingSnapshot
        }
        contextMenuState.pendingWorkspaceSnapshot = nil
    }
}
