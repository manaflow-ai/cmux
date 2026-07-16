#if DEBUG && os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Deterministic real-app fixture for notification-feed interaction and visual
/// verification. It mounts the production tab scaffold and production feed.
public struct NotificationFeedPreviewView: View {
    @State private var selectedTab: MobilePrimaryTab = .notifications
    @State private var items: [MobileNotificationFeedItem]
    @State private var openedWorkspaceName: String?

    public init() {
        _items = State(initialValue: Self.makeFixtureItems(referenceDate: .now))
    }

    public var body: some View {
        MobilePrimaryTabScaffold(
            selection: $selectedTab,
            notificationUnreadCount: items.lazy.filter { !$0.isRead }.count
        ) {
            NotificationFeedPreviewWorkspacesView()
        } notifications: {
            NavigationStack {
                NotificationFeedView(
                    items: items,
                    status: .ready,
                    actions: actions
                )
            }
            .overlay(alignment: .bottom) {
                if let openedWorkspaceName {
                    NotificationFeedPreviewOpenResponse(workspaceName: openedWorkspaceName)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private var actions: NotificationFeedActions {
        NotificationFeedActions(
            open: { item in
                openedWorkspaceName = item.workspaceTitle
                    ?? L10n.string("mobile.notificationFeed.workspaceFallback", defaultValue: "Workspace")
                setRead(true, for: item.id)
            },
            markRead: { item in
                setRead(true, for: item.id)
            },
            markAllRead: {
                items = items.map { $0.updating(isRead: true) }
            },
            refresh: {}
        )
    }

    private func setRead(_ isRead: Bool, for id: MobileNotificationFeedItemID) {
        items = items.map { item in
            item.id == id ? item.updating(isRead: isRead) : item
        }
    }

    private static func makeFixtureItems(referenceDate: Date) -> [MobileNotificationFeedItem] {
        let calendar = Calendar.autoupdatingCurrent
        let startOfToday = calendar.startOfDay(for: referenceDate)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? referenceDate

        return [
            MobileNotificationFeedItem(
                macDeviceID: "studio",
                notificationID: "codex-approval",
                macDisplayName: L10n.string("mobile.notificationFeed.preview.mac.studio", defaultValue: "Studio"),
                remoteWorkspaceID: "workspace-ios-feed",
                remoteSurfaceID: "surface-codex",
                title: L10n.string(
                    "mobile.notificationFeed.preview.approval.title",
                    defaultValue: "Codex needs approval"
                ),
                subtitle: L10n.string(
                    "mobile.notificationFeed.preview.approval.subtitle",
                    defaultValue: "Notification feed"
                ),
                body: L10n.string(
                    "mobile.notificationFeed.preview.approval.body",
                    defaultValue: "The feed is ready to open in the iOS app. Review the navigation and approve the final interaction pass."
                ),
                createdAt: referenceDate.addingTimeInterval(-7 * 60),
                isRead: false,
                workspaceTitle: L10n.string(
                    "mobile.notificationFeed.preview.workspace.ios",
                    defaultValue: "cmux iOS"
                ),
                surfaceTitle: L10n.string("mobile.notificationFeed.preview.surface.codex", defaultValue: "Codex"),
                connectionStatus: .connected
            ),
            MobileNotificationFeedItem(
                macDeviceID: "macbook",
                notificationID: "tests-passed",
                macDisplayName: L10n.string(
                    "mobile.notificationFeed.preview.mac.macBookPro",
                    defaultValue: "MacBook Pro"
                ),
                remoteWorkspaceID: "workspace-release",
                remoteSurfaceID: "surface-tests",
                title: L10n.string(
                    "mobile.notificationFeed.preview.tests.title",
                    defaultValue: "Tests passed"
                ),
                subtitle: L10n.string(
                    "mobile.notificationFeed.preview.tests.subtitle",
                    defaultValue: "Release preparation"
                ),
                body: L10n.string(
                    "mobile.notificationFeed.preview.tests.body",
                    defaultValue: "All focused iOS notification tests passed in 42 seconds."
                ),
                createdAt: referenceDate.addingTimeInterval(-34 * 60),
                isRead: false,
                workspaceTitle: L10n.string(
                    "mobile.notificationFeed.preview.workspace.release",
                    defaultValue: "Release"
                ),
                surfaceTitle: L10n.string("mobile.notificationFeed.preview.surface.tests", defaultValue: "Tests"),
                connectionStatus: .connected
            ),
            MobileNotificationFeedItem(
                macDeviceID: "studio",
                notificationID: "localization-complete",
                macDisplayName: L10n.string("mobile.notificationFeed.preview.mac.studio", defaultValue: "Studio"),
                remoteWorkspaceID: "workspace-localization",
                remoteSurfaceID: "surface-agent",
                title: L10n.string(
                    "mobile.notificationFeed.preview.localization.title",
                    defaultValue: "Localization complete"
                ),
                subtitle: nil,
                body: L10n.string(
                    "mobile.notificationFeed.preview.localization.body",
                    defaultValue: "English and Japanese notification-feed strings are ready."
                ),
                createdAt: referenceDate.addingTimeInterval(-2 * 60 * 60),
                isRead: true,
                workspaceTitle: L10n.string(
                    "mobile.notificationFeed.preview.workspace.localization",
                    defaultValue: "Localization"
                ),
                surfaceTitle: L10n.string("mobile.notificationFeed.preview.surface.agent", defaultValue: "Agent"),
                connectionStatus: .connected
            ),
            MobileNotificationFeedItem(
                macDeviceID: "build-mac",
                notificationID: "input-needed",
                macDisplayName: L10n.string(
                    "mobile.notificationFeed.preview.mac.build",
                    defaultValue: "Build Mac"
                ),
                remoteWorkspaceID: "workspace-cloud",
                remoteSurfaceID: "surface-cloud",
                title: L10n.string(
                    "mobile.notificationFeed.preview.input.title",
                    defaultValue: "Input needed"
                ),
                subtitle: L10n.string(
                    "mobile.notificationFeed.preview.input.subtitle",
                    defaultValue: "Cloud build"
                ),
                body: L10n.string(
                    "mobile.notificationFeed.preview.input.body",
                    defaultValue: "Choose whether to retry the unavailable builder or keep the current artifact. This longer message verifies wrapping without hiding the workspace and Mac context below it."
                ),
                createdAt: calendar.date(byAdding: .hour, value: 17, to: yesterday) ?? yesterday,
                isRead: false,
                workspaceTitle: L10n.string(
                    "mobile.notificationFeed.preview.workspace.cloudBuilder",
                    defaultValue: "Cloud Builder"
                ),
                surfaceTitle: L10n.string("mobile.notificationFeed.preview.surface.build", defaultValue: "Build"),
                connectionStatus: .unavailable
            ),
            MobileNotificationFeedItem(
                macDeviceID: "macbook",
                notificationID: "agent-finished",
                macDisplayName: L10n.string(
                    "mobile.notificationFeed.preview.mac.macBookPro",
                    defaultValue: "MacBook Pro"
                ),
                remoteWorkspaceID: "workspace-docs",
                remoteSurfaceID: "surface-docs",
                title: L10n.string(
                    "mobile.notificationFeed.preview.finished.title",
                    defaultValue: "Agent finished"
                ),
                subtitle: L10n.string(
                    "mobile.notificationFeed.preview.finished.subtitle",
                    defaultValue: "Documentation"
                ),
                body: L10n.string(
                    "mobile.notificationFeed.preview.finished.body",
                    defaultValue: "The onboarding copy now explains the notification history."
                ),
                createdAt: calendar.date(byAdding: .hour, value: 11, to: yesterday) ?? yesterday,
                isRead: true,
                workspaceTitle: L10n.string(
                    "mobile.notificationFeed.preview.workspace.docs",
                    defaultValue: "Docs"
                ),
                surfaceTitle: L10n.string("mobile.notificationFeed.preview.surface.agent", defaultValue: "Agent"),
                connectionStatus: .reconnecting
            ),
        ]
    }
}

private struct NotificationFeedPreviewWorkspacesView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                L10n.string("mobile.tabs.workspaces", defaultValue: "Workspaces"),
                systemImage: "rectangle.stack"
            )
            .navigationTitle(L10n.string("mobile.tabs.workspaces", defaultValue: "Workspaces"))
        }
    }
}

private struct NotificationFeedPreviewOpenResponse: View {
    let workspaceName: String

    var body: some View {
        Label(
            String(
                format: L10n.string(
                    "mobile.notificationFeed.preview.openedFormat",
                    defaultValue: "Opened %@"
                ),
                workspaceName
            ),
            systemImage: "arrow.up.forward.app"
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .accessibilityIdentifier("MobileNotificationFeedPreviewOpenResponse")
    }
}
#endif
