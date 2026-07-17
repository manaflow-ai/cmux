#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// DEBUG-only workspace list fixture for simulator layout screenshots.
///
/// Mounted by the root view when `CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1`.
/// It exercises the production `WorkspaceListView` and row components with a
/// static unread row, avoiding auth and Mac pairing while keeping layout code
/// identical to the real shell.
public struct WorkspaceListLayoutPreviewView: View {
    @State private var selectedWorkspaceID: MobileWorkspacePreview.ID?
    @State private var macSelection: WorkspaceMacSelection = .all
    @State private var workspaces: [MobileWorkspacePreview]
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
        if seedCount > 0 {
            let groupCount = environment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW_GROUPS"].flatMap(Int.init) ?? 0
            (initialWorkspaces, groups) = Self.seeded(count: seedCount, groupCount: groupCount)
        } else {
            initialWorkspaces = Self.defaultWorkspaces
            groups = []
        }
        self.reorderEnabled = reorderEnabled
        _workspaces = State(
            initialValue: reorderEnabled
                ? initialWorkspaces.map { workspace in
                    var workspace = workspace
                    workspace.windowID = "preview-window"
                    workspace.actionCapabilities.supportsMoveActions = true
                    // Interactive fixture: light up every row affordance so
                    // swipes, context menus, rename, and delete are
                    // dogfoodable against local state without a paired Mac.
                    workspace.actionCapabilities.supportsWorkspaceActions = true
                    workspace.actionCapabilities.supportsReadStateActions = true
                    workspace.actionCapabilities.supportsCloseActions = true
                    return workspace
                }
                : initialWorkspaces
        )
    }

    /// Tap-to-open target in the interactive fixture: a trivial pushed detail
    /// proving row selection navigates, without a real workspace shell.
    private struct FixtureWorkspaceRoute: Identifiable, Hashable {
        let id: MobileWorkspacePreview.ID
    }

    @State private var fixtureRoute: FixtureWorkspaceRoute?

    private var scrollMetricsEnabled: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_SCROLL_METRICS"] == "1"
    }

    private var scrollSweepEnabled: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_SCROLL_SWEEP"] == "1"
    }

    private let groups: [MobileWorkspaceGroupPreview]
    private let reorderEnabled: Bool

    private static let defaultWorkspaces: [MobileWorkspacePreview] = [
        MobileWorkspacePreview(
            id: "workspace-main",
            macDeviceID: "preview-macbook-pro",
            macDisplayName: "MacBook Pro",
            name: "cmux",
            terminals: [
                MobileTerminalPreview(id: "terminal-build", name: "Build"),
                MobileTerminalPreview(id: "terminal-agent", name: "Agent"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-ios",
            macDeviceID: "preview-macbook-pro",
            macDisplayName: "MacBook Pro",
            name: "iOS avatar tuning",
            hasUnread: true,
            terminals: [
                MobileTerminalPreview(id: "terminal-ios", name: "Agent"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-docs",
            macDeviceID: "preview-studio",
            macDisplayName: "Studio Display Bench With A Very Long Name",
            name: "Docs",
            terminals: [
                MobileTerminalPreview(id: "terminal-notes", name: "Notes"),
            ]
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
            let groupID = inGroup
                ? MobileWorkspaceGroupPreview.ID(rawValue: "seed-group-\(groupIndex)") : nil
            let id = MobileWorkspacePreview.ID(rawValue: "workspace-seed-\(index)")
            if inGroup, index % 4 == 0, let groupID {
                groups.append(
                    MobileWorkspaceGroupPreview(
                        id: groupID,
                        name: "Group \(groupIndex + 1)",
                        anchorWorkspaceID: id
                    )
                )
            }
            return MobileWorkspacePreview(
                id: id,
                macDeviceID: "preview-macbook-pro",
                macDisplayName: "MacBook Pro",
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
        }
        return (workspaces, groups)
    }

    private var showNotificationBanner: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_NOTIFICATION_BANNER"] == "1"
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
                NavigationStack {
                    WorkspaceListView(
                        workspaces: workspaces,
                        groups: groups,
                        selectedWorkspaceID: selectedWorkspaceID,
                        host: "Visual Mock Mac",
                        connectionStatus: .connected,
                        navigationStyle: .push,
                        wrapWorkspaceTitles: false,
                        previewLineLimit: MobileDisplaySettings.defaultWorkspacePreviewLineCount,
                        unreadIndicatorLeftShift: MobileDisplaySettings.defaultUnreadIndicatorLeftShift,
                        profilePictureLeftShift: MobileDisplaySettings.defaultProfilePictureLeftShift,
                        profilePictureSize: MobileDisplaySettings.defaultProfilePictureSize,
                        selectWorkspace: { id in
                            selectedWorkspaceID = id
                            if reorderEnabled {
                                fixtureRoute = FixtureWorkspaceRoute(id: id)
                            }
                        },
                        createWorkspace: {},
                        macSelection: $macSelection,
                        renameWorkspace: reorderEnabled ? { id, newName in
                            if let index = workspaces.firstIndex(where: { $0.id == id }) {
                                workspaces[index].name = newName
                            }
                        } : nil,
                        setPinned: reorderEnabled ? { id, pinned in
                            if let index = workspaces.firstIndex(where: { $0.id == id }) {
                                workspaces[index].isPinned = pinned
                            }
                        } : nil,
                        setUnread: reorderEnabled ? { id, unread in
                            if let index = workspaces.firstIndex(where: { $0.id == id }) {
                                workspaces[index].hasUnread = unread
                            }
                        } : nil,
                        closeWorkspace: reorderEnabled ? { id in
                            workspaces.removeAll { $0.id == id }
                        } : nil,
                        moveWorkspace: reorderEnabled ? { id, groupID, beforeWorkspaceID, movesGroup in
                            workspaces = workspaces.applyingWorkspaceMoveIntent(
                                MobileWorkspaceMoveIntent(
                                    groupID: groupID,
                                    beforeWorkspaceID: beforeWorkspaceID,
                                    movesGroup: movesGroup
                                ),
                                movedWorkspaceID: id,
                                groups: groups
                            )
                            return true
                        } : nil
                    )
                    .navigationDestination(item: $fixtureRoute) { route in
                        VStack(spacing: 12) {
                            Text(
                                workspaces.first(where: { $0.id == route.id })?.name
                                    ?? route.id.rawValue
                            )
                            .font(.title2)
                            Text("Fixture workspace detail")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("FixtureWorkspaceDetail")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if scrollMetricsEnabled {
                        WorkspaceListScrollMetricsProbe(runsSweep: scrollSweepEnabled)
                            .frame(width: 1, height: 1)
                            .accessibilityHidden(true)
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
        }
    }
}
#endif
