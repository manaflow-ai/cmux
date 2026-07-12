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
    @State private var workspaces = Self.initialWorkspaces
    @State private var searchStressComplete = false

    public init() {}

    private static let initialWorkspaces: [MobileWorkspacePreview] = [
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

    public var body: some View {
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
                    selectedWorkspaceID: selectedWorkspaceID,
                    host: "Visual Mock Mac",
                    connectionStatus: .connected,
                    navigationStyle: .push,
                    wrapWorkspaceTitles: false,
                    previewLineLimit: MobileDisplaySettings.defaultWorkspacePreviewLineCount,
                    unreadIndicatorLeftShift: MobileDisplaySettings.defaultUnreadIndicatorLeftShift,
                    profilePictureLeftShift: MobileDisplaySettings.defaultProfilePictureLeftShift,
                    profilePictureSize: MobileDisplaySettings.defaultProfilePictureSize,
                    selectWorkspace: { selectedWorkspaceID = $0 },
                    createWorkspace: {},
                    macSelection: $macSelection
                )
            }
            .overlay(alignment: .bottomTrailing) {
                if searchStressComplete {
                    Text("MobileWorkspaceSearchStressComplete")
                        .font(.caption2)
                        .accessibilityIdentifier("MobileWorkspaceSearchStressComplete")
                }
            }
            .task {
                guard UITestConfig.workspaceListSearchStressEnabled else { return }
                for revision in 0..<400 {
                    guard !Task.isCancelled else { return }
                    workspaces[0].previewText = "Build output revision \(revision)"
                    await Task.yield()
                }
                searchStressComplete = true
            }
        }
    }
}
#endif
