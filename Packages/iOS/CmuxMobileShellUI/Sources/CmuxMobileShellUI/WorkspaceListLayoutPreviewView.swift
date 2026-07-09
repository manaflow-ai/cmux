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
    // Safety: DEBUG screenshot-only presenter is owned by this preview view and
    // only mutates its fired flag from the SwiftUI task that requests the banner.
    private let notificationPresenter = ScreenshotNotificationPresenter()

    /// Creates a static workspace-list preview for App Store screenshot capture.
    public init() {}

    private let workspaces: [MobileWorkspacePreview] = [
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
