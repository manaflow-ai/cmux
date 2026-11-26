import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

/// Behavior coverage for the presentation strings the projection builds off
/// the main actor. The workspace title is the row headline; the notification
/// title ("Claude Code") is secondary provenance and disappears when it
/// repeats the headline.
@Suite struct NotificationFeedRowModelTests {
    @Test func workspaceTitleIsTheHeadlineAndTitleBecomesTheSource() {
        let model = NotificationFeedRowModel(item: item(
            title: "Claude Code",
            workspaceTitle: "Fix login flake"
        ))

        #expect(model.presentation.headline == "Fix login flake")
        #expect(model.presentation.sourceName == "Claude Code")
    }

    @Test func titleMatchingIsCaseWhitespaceAndDiacriticInsensitive() {
        let model = NotificationFeedRowModel(item: item(
            title: "  Résumé   Review ",
            workspaceTitle: "resume review"
        ))

        #expect(model.presentation.headline == "resume review")
        #expect(model.presentation.sourceName == nil)
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

    @Test func missingWorkspaceFallsBackToTitleHeadlineAndBlankComputerUsesDeviceID() {
        let model = NotificationFeedRowModel(item: item(
            workspaceTitle: "   ",
            macDisplayName: " "
        ))

        #expect(model.presentation.headline == "Title")
        #expect(model.presentation.sourceName == nil)
        #expect(model.presentation.computerName == "mac-a")
    }

    @Test func blankTitleAndWorkspaceUseTheUnknownWorkspaceHeadline() {
        let model = NotificationFeedRowModel(item: item(
            title: " ",
            workspaceTitle: ""
        ))

        #expect(model.presentation.headline == "Unknown workspace")
        #expect(model.presentation.sourceName == nil)
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

    @Test func accessibilityDetailsCarryReadStateSourcePreviewAndComputer() {
        let unread = NotificationFeedRowModel(item: item(
            isRead: false,
            body: "Choose a builder to continue.",
            connectionStatus: .unavailable
        ))

        #expect(unread.presentation.accessibilityDetails == [
            "Unread",
            "From: Title",
            "Choose a builder to continue.",
            "Connection: Mac · Unavailable",
        ])

        let read = NotificationFeedRowModel(item: item(isRead: true))
        #expect(read.presentation.accessibilityDetails.first == "Read")

        // A title that repeats the workspace adds nothing, so it is not spoken.
        let redundantTitle = NotificationFeedRowModel(item: item(
            title: "Workspace",
            workspaceTitle: "Workspace"
        ))
        #expect(!redundantTitle.presentation.accessibilityDetails
            .contains { $0.hasPrefix("From:") })
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
