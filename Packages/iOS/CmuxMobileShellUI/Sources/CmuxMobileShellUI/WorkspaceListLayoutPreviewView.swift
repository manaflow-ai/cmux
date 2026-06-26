#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI
import UserNotifications

/// Drives a REAL iOS notification for the App Store "notifications" screenshot.
///
/// Instead of drawing a fake banner, this requests notification authorization
/// and schedules a genuine local notification, so the system renders the actual
/// banner (real blur, fonts, the app's real icon, and the app's display name
/// "cmux"). The snapshot UITest taps the springboard "Allow" prompt and captures
/// the real `NotificationShortLookView`. Foreground presentation as a banner is
/// handled by `CmuxAppDelegate.willPresent` (returns `.banner` here since no push
/// coordinator is wired in preview mode); we also set a delegate as a fallback.
final class ScreenshotNotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ScreenshotNotificationPresenter()
    private var fired = false

    func fire() {
        guard !fired else { return }
        fired = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Agent needs your input"
            content.body = "Claude is asking: which database should I use, Postgres or SQLite?"
            content.sound = .default
            // Fire soon after authorization is granted; the UITest snapshots the
            // banner the instant it appears (iOS banners auto-dismiss in ~5s).
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.6, repeats: false)
            center.add(UNNotificationRequest(
                identifier: "cmux-screenshot-agent",
                content: content,
                trigger: trigger
            ))
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// DEBUG-only workspace list fixture for simulator layout screenshots.
///
/// Mounted by the root view when `CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1`.
/// It exercises the production `WorkspaceListView` and row components with a
/// static unread row, avoiding auth and Mac pairing while keeping layout code
/// identical to the real shell.
struct WorkspaceListLayoutPreviewView: View {
    @State private var selectedWorkspaceID: MobileWorkspacePreview.ID?

    private let workspaces: [MobileWorkspacePreview] = [
        MobileWorkspacePreview(
            id: "workspace-main",
            name: "cmux",
            terminals: [
                MobileTerminalPreview(id: "terminal-build", name: "Build"),
                MobileTerminalPreview(id: "terminal-agent", name: "Agent"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-ios",
            name: "iOS avatar tuning",
            hasUnread: true,
            terminals: [
                MobileTerminalPreview(id: "terminal-ios", name: "Agent"),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-docs",
            name: "Docs",
            terminals: [
                MobileTerminalPreview(id: "terminal-notes", name: "Notes"),
            ]
        ),
    ]

    private var showNotificationBanner: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_NOTIFICATION_BANNER"] == "1"
    }

    var body: some View {
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
                createWorkspace: {}
            )
        }
        .task {
            // Fire a REAL local notification (not a drawn banner) so the system
            // renders the genuine banner over this workspace list.
            if showNotificationBanner {
                ScreenshotNotificationPresenter.shared.fire()
            }
        }
    }
}
#endif
