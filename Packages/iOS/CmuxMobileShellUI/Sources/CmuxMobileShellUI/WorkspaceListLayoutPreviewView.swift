#if canImport(UIKit) && DEBUG
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import Observation
import SwiftUI

/// Owns the mutable rows and live-update stimulus for the DEBUG preview.
@MainActor
@Observable
private final class WorkspaceListLayoutPreviewModel {
    /// The continuous update feed's payload shape
    /// (`CMUX_UITEST_WORKSPACE_LIST_PREVIEW_LIVE_UPDATES`).
    enum LiveUpdateMode {
        /// No feed.
        case off
        /// `1`: visible churn — unread toggles plus activity restamps.
        case visible
        /// `timestamps`: sub-minute activity restamps only, the shape the Mac
        /// emits while agents stream (`last_activity_at` is the latest
        /// notification's `createdAt`). Rows render identically, so a correct
        /// list does zero work per tick.
        case timestampsOnly
    }

    var workspaces: [MobileWorkspacePreview]
    var groups: [MobileWorkspaceGroupPreview]
    private let liveUpdateMode: LiveUpdateMode

    /// Creates a preview model with an optional continuous update feed.
    init(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview],
        liveUpdateMode: LiveUpdateMode
    ) {
        self.workspaces = workspaces
        self.groups = groups
        self.liveUpdateMode = liveUpdateMode
    }

    /// Mutates rotating row payloads until the view-owned task is cancelled.
    func runLiveUpdates() async {
        guard liveUpdateMode != .off else { return }
        var updateLane = 0
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            for index in workspaces.indices where index % 10 == updateLane {
                if liveUpdateMode == .visible {
                    workspaces[index].hasUnread.toggle()
                    workspaces[index].previewAt = Date()
                    workspaces[index].lastActivityAt = Date()
                } else {
                    // Restamp relative to the row's own clock: the seeded
                    // timestamps are hours old, so jumping them to `Date()`
                    // would change the rendered minute on every row's first
                    // tick and do real row work. The bump also wraps back to
                    // the start of the row's current minute rather than
                    // crossing into the next one, so EVERY tick is a
                    // render-equivalent delta (this mode's zero-work
                    // contract), not just the first fifty-nine.
                    let current = workspaces[index].lastActivityAt
                        ?? workspaces[index].previewAt
                        ?? Date()
                    let minute = (current.timeIntervalSinceReferenceDate / 60)
                        .rounded(.down)
                    var restamped = current.addingTimeInterval(1)
                    if (restamped.timeIntervalSinceReferenceDate / 60).rounded(.down) != minute {
                        restamped = Date(timeIntervalSinceReferenceDate: minute * 60)
                    }
                    workspaces[index].previewAt = restamped
                    workspaces[index].lastActivityAt = restamped
                }
            }
            updateLane = (updateLane + 1) % 10
        }
    }

    func rotateForRefresh() {
        let current = workspaces
        workspaces = Array(current.dropFirst()) + Array(current.prefix(1))
    }
}

/// DEBUG-only workspace list fixture for simulator layout screenshots.
///
/// Mounted by the root view when `CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1`.
/// It exercises the production `WorkspaceListView` and row components with a
/// static unread row, avoiding auth and Mac pairing while keeping layout code
/// identical to the real shell.
public struct WorkspaceListLayoutPreviewView: View {
    @State private var selectedWorkspaceID: MobileWorkspacePreview.ID?
    @State private var macSelection: WorkspaceMacSelection = .all
    @State private var refreshGeneration = 0
    @State private var model: WorkspaceListLayoutPreviewModel
    @State private var selectedPrimaryTab: MobilePrimaryTab = .workspaces
    @State private var primarySearchCoordinator = MobilePrimarySearchCoordinator()
    @State private var filterState = WorkspaceListFilterState()
    /// Store-free stand-ins for the device-local sort preference, so the
    /// fixture's sort menu and computer-order editor are fully interactive.
    /// `CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SORT` (a raw mode value) and
    /// `..._SORT_PRIORITY` (comma-separated Mac device ids) seed them so a
    /// harness can verify each mode's rendering without driving the menu.
    @State private var fixtureSortMode: MobileWorkspaceSortMode =
        ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SORT"]
            .flatMap(MobileWorkspaceSortMode.init(rawValue:)) ?? .automatic
    @State private var fixtureComputerPriority: [String] =
        ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SORT_PRIORITY"]
            .map { $0.split(separator: ",").map(String.init) } ?? []
    // Safety: DEBUG screenshot-only presenter is owned by this preview view and
    // only mutates its fired flag from the SwiftUI task that requests the banner.
    private let notificationPresenter = ScreenshotNotificationPresenter()

    /// Creates a static workspace-list preview for App Store screenshot capture.
    ///
    /// With `CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT=<n>` the fixture seeds
    /// `n` deterministic rows (plus `CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS`
    /// leading groups) instead of the static screenshot trio, for scroll
    /// measurement.
    public init() {
        let environment = ProcessInfo.processInfo.environment
        let seedCount = environment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT"].flatMap(Int.init) ?? 0
        let reorderEnabled = environment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW_REORDER"] == "1"
        let initialWorkspaces: [MobileWorkspacePreview]
        let initialGroups: [MobileWorkspaceGroupPreview]
        if seedCount > 0 {
            let groupCount = environment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS"].flatMap(Int.init) ?? 0
            (initialWorkspaces, initialGroups) = Self.seeded(
                count: seedCount,
                groupCount: groupCount
            )
        } else {
            initialWorkspaces = Self.defaultWorkspaces
            initialGroups = []
        }
        self.reorderEnabled = reorderEnabled
        let fixtureWorkspaces = reorderEnabled
            ? initialWorkspaces.map { workspace in
                var workspace = workspace
                workspace.windowID = "preview-window"
                workspace.actionCapabilities.supportsMoveActions = true
                // Interactive fixture: light up every row affordance so
                // swipes, context menus, rename, and delete are
                // dogfoodable against local state without a paired Mac.
                workspace.actionCapabilities.supportsWorkspaceActions = true
                workspace.actionCapabilities.supportsWorkspaceMetadata = true
                workspace.actionCapabilities.supportsReadStateActions = true
                workspace.actionCapabilities.supportsCloseActions = true
                workspace.actionCapabilities.supportsGroupActions = true
                return workspace
            }
            : initialWorkspaces
        let liveUpdateMode: WorkspaceListLayoutPreviewModel.LiveUpdateMode
        switch environment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW_LIVE_UPDATES"] {
        case "1": liveUpdateMode = .visible
        case "timestamps": liveUpdateMode = .timestampsOnly
        default: liveUpdateMode = .off
        }
        _model = State(
            initialValue: WorkspaceListLayoutPreviewModel(
                workspaces: fixtureWorkspaces,
                groups: initialGroups,
                liveUpdateMode: liveUpdateMode
            )
        )
    }

    /// Tap-to-open target in the interactive fixture: a trivial pushed detail
    /// proving row selection navigates, without a real workspace shell.
    private struct FixtureWorkspaceRoute: Identifiable, Hashable {
        let id: MobileWorkspacePreview.ID
    }

    @State private var fixtureRoute: FixtureWorkspaceRoute?
    @State private var pendingSearchFixtureRoute: FixtureWorkspaceRoute?

    private var scrollMetricsEnabled: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_SCROLL_METRICS"] == "1"
    }

    private var scrollSweepEnabled: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_SCROLL_SWEEP"] == "1"
    }

    private let reorderEnabled: Bool

    /// A stable clock-time for seeded activity: capture rigs show these rows
    /// under an 11:41 status bar, so same-day times stay in the morning and
    /// `daysAgo` rows exercise the month/day trailing label.
    private static func seedActivityTime(hour: Int, minute: Int, daysAgo: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static let defaultWorkspaces: [MobileWorkspacePreview] = [
        MobileWorkspacePreview(
            id: "workspace-login-crash",
            macDeviceID: "preview-macbook-pro",
            macDisplayName: "MacBook Pro",
            name: "Fix login crash",
            previewText: "Claude: found the session-restore race. 3 files changed, regression test added, PR opened.",
            previewAt: seedActivityTime(hour: 11, minute: 32),
            lastActivityAt: seedActivityTime(hour: 11, minute: 32),
            hasUnread: true,
            terminals: [
                MobileTerminalPreview(id: "terminal-login-agent", name: "Agent"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-main",
            macDeviceID: "preview-macbook-pro",
            macDisplayName: "MacBook Pro",
            name: "cmux",
            previewText: "Build succeeded in 3m 41s, 214 tests green",
            previewAt: seedActivityTime(hour: 11, minute: 18),
            lastActivityAt: seedActivityTime(hour: 11, minute: 18),
            terminals: [
                MobileTerminalPreview(id: "terminal-build", name: "Build"),
                MobileTerminalPreview(id: "terminal-agent", name: "Agent"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-rate-limit",
            macDeviceID: "preview-macbook-pro",
            macDisplayName: "MacBook Pro",
            name: "API rate limiting",
            previewText: "Codex needs approval: retry 429s with exponential backoff?",
            previewAt: seedActivityTime(hour: 10, minute: 47),
            lastActivityAt: seedActivityTime(hour: 10, minute: 47),
            hasUnread: true,
            terminals: [
                MobileTerminalPreview(id: "terminal-rate-agent", name: "Agent"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-dark-mode",
            macDeviceID: "preview-macbook-pro",
            macDisplayName: "MacBook Pro",
            name: "Dark mode pass",
            previewText: "Screenshot diff clean across all 12 screens",
            previewAt: seedActivityTime(hour: 9, minute: 54),
            lastActivityAt: seedActivityTime(hour: 9, minute: 54),
            terminals: [
                MobileTerminalPreview(id: "terminal-dark-agent", name: "Agent"),
                MobileTerminalPreview(id: "terminal-dark-tests", name: "Tests"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-docs",
            macDeviceID: "preview-studio",
            macDisplayName: "Studio Display Bench With A Very Long Name",
            name: "Docs",
            previewText: "Getting-started guide rewritten for the new pairing flow",
            previewAt: seedActivityTime(hour: 9, minute: 12),
            lastActivityAt: seedActivityTime(hour: 9, minute: 12),
            terminals: [
                MobileTerminalPreview(id: "terminal-notes", name: "Notes"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-release",
            macDeviceID: "preview-macbook-pro",
            macDisplayName: "MacBook Pro",
            name: "Release 1.4",
            previewText: "Archive uploaded to TestFlight",
            previewAt: seedActivityTime(hour: 18, minute: 6, daysAgo: 1),
            lastActivityAt: seedActivityTime(hour: 18, minute: 6, daysAgo: 1),
            terminals: [
                MobileTerminalPreview(id: "terminal-release-build", name: "Build"),
            ]
        ),
    ]

    static let previewPairedMacs: [MobilePairedMac] = [
        MobilePairedMac(
            macDeviceID: "preview-macbook-pro",
            displayName: "MacBook Pro",
            routes: [],
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: 2),
            isActive: true,
            stackUserID: nil,
            instanceTag: "nightly"
        ),
        MobilePairedMac(
            macDeviceID: "preview-macbook-pro",
            displayName: "MacBook Pro",
            routes: [],
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: 1),
            isActive: false,
            stackUserID: nil,
            instanceTag: "stable"
        ),
        MobilePairedMac(
            macDeviceID: "preview-studio",
            displayName: "Studio Display Bench With A Very Long Name",
            routes: [],
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: 0),
            isActive: false,
            stackUserID: nil,
            instanceTag: "stable"
        ),
    ]

    private static let seedNames = [
        "cmux", "iOS avatar tuning", "Docs", "Sidebar perf", "Typing latency",
        "Release prep", "Chip gallery", "Diff viewer", "Workspace todos", "Super search",
    ]
    private static let seedPreviews = [
        "Build succeeded in 214s",
        "Agent finished: 3 files changed, tests green, PR opened for review",
        "Waiting for dogfood verdict",
        "codex: refactored the reconciler and re-ran the focused suite twice",
        "CI green on head",
    ]

    /// Deterministic long-list seeding for scroll measurement
    /// (`CMUX_UITEST_WORKSPACE_LIST_PREVIEW_COUNT`, optional
    /// `CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS`). Every 4th row is unread,
    /// preview lengths vary, and with `g` groups the first `g * 4` rows fold
    /// into anchored groups of 4 (anchor + 3 members) so headers and
    /// end-of-group drop slots render like a real grouped list.
    private static func seeded(
        count: Int, groupCount: Int
    ) -> ([MobileWorkspacePreview], [MobileWorkspaceGroupPreview]) {
        let anchorTime = Date(timeIntervalSinceNow: -60)
        var groups: [MobileWorkspaceGroupPreview] = []
        let workspaces = (0..<count).map { index -> MobileWorkspacePreview in
            let groupIndex = index / 4
            let inGroup = groupIndex < groupCount
            let macDeviceID = inGroup && !groupIndex.isMultiple(of: 2)
                ? "preview-studio" : "preview-macbook-pro"
            let macDisplayName = macDeviceID == "preview-studio"
                ? "Studio Display Bench With A Very Long Name" : "MacBook Pro"
            let macInstanceTag = macDeviceID == "preview-studio" ? "stable" : "nightly"
            let groupID = inGroup
                ? MobileWorkspaceGroupPreview.ID(rawValue: "seed-group-\(groupIndex)") : nil
            let id = MobileWorkspacePreview.ID(rawValue: "workspace-seed-\(index)")
            if inGroup, index % 4 == 0, let groupID {
                groups.append(
                    MobileWorkspaceGroupPreview(
                        id: groupID,
                        macDeviceID: macDeviceID,
                        macInstanceTag: macInstanceTag,
                        name: "Group \(groupIndex + 1)",
                        anchorWorkspaceID: id
                    )
                )
            }
            var workspace = MobileWorkspacePreview(
                id: id,
                macDeviceID: macDeviceID,
                macDisplayName: macDisplayName,
                name: "\(seedNames[index % seedNames.count]) \(index)",
                groupID: groupID,
                previewText: seedPreviews[index % seedPreviews.count],
                previewAt: anchorTime.addingTimeInterval(-Double(index) * 3600),
                lastActivityAt: anchorTime.addingTimeInterval(-Double(index) * 3600),
                hasUnread: index % 4 == 0,
                terminals: [
                    MobileTerminalPreview(
                        id: MobileTerminalPreview.ID(rawValue: "terminal-seed-\(index)"),
                        name: "Agent"
                    ),
                ]
            )
            workspace.macInstanceTag = macInstanceTag
            return workspace
        }
        return (workspaces, groups)
    }

    private var showNotificationBanner: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_NOTIFICATION_BANNER"] == "1"
    }

    /// `CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS=1` wraps the list in a tab
    /// scaffold mirroring the shell's TabView, so scroll-edge behavior against
    /// the real floating tab bar can be exercised without Mac pairing. Off by
    /// default: the App Store screenshot rig expects the bare list chrome.
    private var showsTabScaffold: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW_TABS"] == "1"
    }

    private func performPreviewRefresh() {
        model.rotateForRefresh()
        refreshGeneration += 1
    }

    /// The fixture's stand-in for the composite's priority-ordered aggregation:
    /// a stable partition of the seeded rows by the chosen computer order.
    /// Group headers follow their members' row positions, so reordering rows
    /// alone reorders the visible sections exactly like the real derivation.
    private var fixtureSortedWorkspaces: [MobileWorkspacePreview] {
        guard fixtureSortMode == .computerPriority, !fixtureComputerPriority.isEmpty else {
            return model.workspaces
        }
        var rank: [String: Int] = [:]
        for (index, deviceID) in fixtureComputerPriority.enumerated()
            where rank[deviceID] == nil {
            rank[deviceID] = index
        }
        return model.workspaces.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank[lhs.element.macDeviceID ?? ""] ?? Int.max
                let rhsRank = rank[rhs.element.macDeviceID ?? ""] ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func workspaceListFixture(searchText: String) -> some View {
        WorkspaceListView(
            workspaces: fixtureSortedWorkspaces,
            groups: model.groups,
            selectedWorkspaceID: selectedWorkspaceID,
            host: "Visual Mock Mac",
            connectionStatus: .connected,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            previewLineLimit: MobileDisplaySettings.defaultWorkspacePreviewLineCount,
            unreadIndicatorLeftShift: MobileDisplaySettings.defaultUnreadIndicatorLeftShift,
            selectWorkspace: { id in
                selectFixtureWorkspace(id)
            },
            createWorkspace: {},
            createWorkspaceInGroup: reorderEnabled ? { _ in } : nil,
            createWorkspaceGroup: reorderEnabled ? {} : nil,
            macSelection: $macSelection,
            refresh: {
                await MainActor.run {
                    performPreviewRefresh()
                }
            },
            renameWorkspace: reorderEnabled ? { id, newName in
                if let index = model.workspaces.firstIndex(where: { $0.id == id }) {
                    model.workspaces[index].name = newName
                }
            } : nil,
            customizeWorkspace: reorderEnabled ? { id, _, submittedDraft in
                guard let index = model.workspaces.firstIndex(where: { $0.id == id }) else {
                    return .failure()
                }
                model.workspaces[index].name = submittedDraft.name
                model.workspaces[index].customDescription = submittedDraft.customDescription
                model.workspaces[index].customDescriptionIsTruncated = false
                model.workspaces[index].customColorHex = submittedDraft.customColorHex
                model.workspaces[index].isPinned = submittedDraft.isPinned
                return .success
            } : nil,
            setPinned: reorderEnabled ? { id, pinned in
                if let index = model.workspaces.firstIndex(where: { $0.id == id }) {
                    model.workspaces[index].isPinned = pinned
                }
            } : nil,
            setUnread: reorderEnabled ? { id, unread in
                if let index = model.workspaces.firstIndex(where: { $0.id == id }) {
                    model.workspaces[index].hasUnread = unread
                }
            } : nil,
            closeWorkspace: reorderEnabled ? { id in
                model.workspaces.removeAll { $0.id == id }
            } : nil,
            moveWorkspace: reorderEnabled ? { id, groupID, beforeWorkspaceID, movesGroup in
                model.workspaces = model.workspaces.applyingWorkspaceMoveIntent(
                    MobileWorkspaceMoveIntent(
                        groupID: groupID,
                        beforeWorkspaceID: beforeWorkspaceID,
                        movesGroup: movesGroup
                    ),
                    movedWorkspaceID: id,
                    groups: model.groups
                )
                return true
            } : nil,
            renameWorkspaceGroup: reorderEnabled ? { id, newName in
                if let index = model.groups.firstIndex(where: { $0.id == id }) {
                    model.groups[index].name = newName
                }
            } : nil,
            setGroupPinned: reorderEnabled ? { id, pinned in
                if let index = model.groups.firstIndex(where: { $0.id == id }) {
                    model.groups[index].isPinned = pinned
                }
            } : nil,
            ungroupWorkspaceGroup: reorderEnabled ? { id in
                for index in model.workspaces.indices
                where model.workspaces[index].groupID == id {
                    model.workspaces[index].groupID = nil
                }
                model.groups.removeAll { $0.id == id }
            } : nil,
            deleteWorkspaceGroup: reorderEnabled ? { id in
                model.workspaces.removeAll { $0.groupID == id }
                model.groups.removeAll { $0.id == id }
            } : nil,
            toggleGroupCollapsed: reorderEnabled ? { groupID, isCollapsed in
                guard let index = model.groups.firstIndex(where: { $0.id == groupID }) else {
                    return
                }
                model.groups[index].isCollapsed = isCollapsed
            } : nil,
            workspaceSortMode: fixtureSortMode,
            setWorkspaceSortMode: { fixtureSortMode = $0 },
            workspaceComputerPriority: fixtureComputerPriority,
            setWorkspaceComputerPriority: { fixtureComputerPriority = $0 },
            filterState: filterState,
            searchText: searchText
        )
    }

    public var body: some View {
        Group {
            if UITestConfig.workspaceDetailCreateDelayedTerminalPreviewEnabled {
                WorkspaceDetailCreateDelayedTerminalPreviewView()
            } else if UITestConfig.workspaceDetailRefreshingTerminalMenuPreviewEnabled {
                WorkspaceDetailDelayedTerminalPreviewView()
            } else if UITestConfig.workspaceDetailDelayedTerminalPreviewEnabled {
                WorkspaceDetailDelayedTerminalPreviewView()
            } else {
                let workspaceListStack = NavigationStack {
                    MobilePrimaryWorkspaceSearchHost(
                        searchCoordinator: primarySearchCoordinator,
                        taskComposerAction: showsTabScaffold ? {} : nil
                    ) { searchText in
                        workspaceListFixture(searchText: searchText)
                    }
                    .navigationDestination(item: $fixtureRoute) { route in
                        VStack(spacing: 12) {
                            Text(
                                model.workspaces.first(where: { $0.id == route.id })?.name
                                    ?? route.id.rawValue
                            )
                            .font(.title2)
                            Text("Fixture workspace detail")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("FixtureWorkspaceDetail")
                        .toolbarVisibility(.hidden, for: .tabBar, .bottomBar)
                        .navigationBarBackButtonHidden(true)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                WorkspaceBackButton(unreadCount: 0) {
                                    fixtureRoute = nil
                                }
                            }
                        }
                    }
                }
                .onAppear {
                    consumePendingSearchFixtureNavigation()
                }
                .onChange(of: pendingSearchFixtureRoute) { _, _ in
                    consumePendingSearchFixtureNavigation()
                }
                .overlay(alignment: .bottomTrailing) {
                    if scrollMetricsEnabled {
                        WorkspaceListScrollMetricsProbe(runsSweep: scrollSweepEnabled)
                            .frame(width: 1, height: 1)
                            .accessibilityHidden(true)
                    }
                }

                if showsTabScaffold {
                    MobilePrimaryTabScaffold(
                        selection: $selectedPrimaryTab,
                        searchCoordinator: primarySearchCoordinator,
                        notificationUnreadCount: 0,
                        taskComposerAction: {}
                    ) {
                        workspaceListStack
                    } notifications: {
                        Text("Notification feed fixture")
                            .foregroundStyle(.secondary)
                    } workspaceSearch: {
                        NavigationStack {
                            MobilePrimaryWorkspaceSearchContentHost(
                                searchCoordinator: primarySearchCoordinator
                            ) { searchText in
                                workspaceListFixture(searchText: searchText)
                            }
                        }
                    } notificationSearch: {
                        Text("Notification feed fixture")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    workspaceListStack
                }
            }
        }
        .onChange(of: primarySearchCoordinator.isPresented) { _, isPresented in
            guard !isPresented else { return }
            consumePendingSearchFixtureNavigation()
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("MobileWorkspaceListRefreshGeneration-\(refreshGeneration)")
                if showsTabScaffold {
                    Button {
                        performPreviewRefresh()
                    } label: {
                        Rectangle()
                            .fill(Color.primary.opacity(0.01))
                            .frame(width: 44, height: 44)
                    }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("MobileWorkspaceListPreviewRefresh")
                        .accessibilityAction {
                            performPreviewRefresh()
                        }
                }
            }
        }
        .task {
            // Fire a REAL local notification (not a drawn banner) so the system
            // renders the genuine banner over this workspace list.
            if showNotificationBanner {
                notificationPresenter.fire()
            }

            await model.runLiveUpdates()
        }
    }

    private func selectFixtureWorkspace(_ id: MobileWorkspacePreview.ID) {
        selectedWorkspaceID = id
        let route = FixtureWorkspaceRoute(id: id)
        if showsTabScaffold,
           selectedPrimaryTab == .search || primarySearchCoordinator.isPresented {
            pendingSearchFixtureRoute = route
            transitionPrimaryTab(to: .workspaces)
        } else {
            fixtureRoute = route
        }
    }

    private func consumePendingSearchFixtureNavigation() {
        guard !primarySearchCoordinator.isPresented,
              selectedPrimaryTab == .workspaces,
              let route = pendingSearchFixtureRoute else { return }
        pendingSearchFixtureRoute = nil
        fixtureRoute = route
    }

    @discardableResult
    private func transitionPrimaryTab(to tab: MobilePrimaryTab) -> Bool {
        let previousTab = selectedPrimaryTab
        if (selectedPrimaryTab == .search || primarySearchCoordinator.isPresented),
           tab.searchScope != nil {
            primarySearchCoordinator.deactivateCurrentSearch()
        }
        selectedPrimaryTab = tab
        return previousTab != tab
    }
}

#endif
