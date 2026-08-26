import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

/// Behavior coverage for the presentation strings the projection now builds
/// off the main actor. These rules used to live inside the row body; they must
/// survive the move byte-for-byte.
@Suite struct NotificationFeedRowModelTests {
    @Test func workspaceMatchingIsCaseWhitespaceAndDiacriticInsensitive() {
        let model = NotificationFeedRowModel(item: item(
            title: "  Résumé   Review ",
            workspaceTitle: "resume review"
        ))

        #expect(model.presentation.workspaceMatchesTitle)
        #expect(model.presentation.workspaceName == "resume review")
    }

    @Test func redundantBodyFallsBackToSubtitleThenNil() {
        let bodyMatchesTitle = NotificationFeedRowModel(item: item(
            title: "Build finished",
            subtitle: "Release pipeline",
            body: "build FINISHED"
        ))
        #expect(bodyMatchesTitle.presentation.contentPreview == "Release pipeline")

        let bothRedundant = NotificationFeedRowModel(item: item(
            title: "Build finished",
            subtitle: "Workspace",
            body: " Build finished "
        ))
        #expect(bothRedundant.presentation.contentPreview == nil)

        let distinctBody = NotificationFeedRowModel(item: item(
            title: "Build finished",
            body: "Artifacts uploaded to the release bucket."
        ))
        #expect(distinctBody.presentation.contentPreview == "Artifacts uploaded to the release bucket.")
    }

    @Test func missingWorkspaceUsesFallbackAndBlankComputerUsesDeviceID() {
        let model = NotificationFeedRowModel(item: item(
            workspaceTitle: "   ",
            macDisplayName: " "
        ))

        #expect(model.presentation.workspaceName == "Unknown workspace")
        #expect(model.presentation.computerName == "mac-a")
    }

    @Test func computerStatusTextReflectsConnectionState() {
        #expect(
            NotificationFeedRowModel(item: item(connectionStatus: .connected))
                .presentation.computerStatusText == "Mac"
        )
        #expect(
            NotificationFeedRowModel(item: item(connectionStatus: .reconnecting))
                .presentation.computerStatusText == "Mac · Reconnecting"
        )
        #expect(
            NotificationFeedRowModel(item: item(connectionStatus: .unavailable))
                .presentation.computerStatusText == "Mac · Unavailable"
        )
    }

    @Test func accessibilityDetailsCarryReadStateWorkspacePreviewAndComputer() {
        let unread = NotificationFeedRowModel(item: item(
            isRead: false,
            body: "Choose a builder to continue.",
            connectionStatus: .unavailable
        ))

        #expect(unread.presentation.accessibilityDetails == [
            "Unread",
            "Workspace: Workspace",
            "Choose a builder to continue.",
            "Computer: Mac · Unavailable",
        ])

        let read = NotificationFeedRowModel(item: item(isRead: true))
        #expect(read.presentation.accessibilityDetails.first == "Read")
    }

    @Test func equalityComparesTheItemAlone() {
        let first = NotificationFeedRowModel(item: item())
        let second = NotificationFeedRowModel(item: item())

        // Same item produced by two separate rebuilds must compare equal so
        // republished sections do not re-render unchanged rows.
        #expect(first == second)
        #expect(first != NotificationFeedRowModel(item: item(isRead: true)))
    }

    private func item(
        isRead: Bool = false,
        title: String = "Title",
        subtitle: String? = nil,
        body: String = "Body",
        workspaceTitle: String = "Workspace",
        macDisplayName: String = "Mac",
        connectionStatus: MobileMacConnectionStatus = .connected
    ) -> MobileNotificationFeedItem {
        MobileNotificationFeedItem(
            macDeviceID: "mac-a",
            notificationID: "notification",
            macDisplayName: macDisplayName,
            remoteWorkspaceID: "workspace",
            remoteSurfaceID: "surface",
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_784_000_000),
            isRead: isRead,
            workspaceTitle: workspaceTitle,
            surfaceTitle: "Terminal",
            connectionStatus: connectionStatus
        )
    }
}
