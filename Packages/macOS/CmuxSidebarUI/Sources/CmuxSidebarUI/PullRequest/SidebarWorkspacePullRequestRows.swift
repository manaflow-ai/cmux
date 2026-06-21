public import CmuxSidebar
public import CoreGraphics
public import SwiftUI

/// The pull-request badge list shown under a workspace row.
///
/// Each badge renders a ``PullRequestStatusIcon``, the PR label + number, and
/// the localized status word. When ``makesClickable`` is set the row becomes a
/// button that calls ``onOpen``; otherwise it is a combined accessibility
/// element. All localized strings (`statusLabel`, `openTooltip`) are resolved
/// by the caller in the app bundle and passed in, so this package view never
/// calls `String(localized:)` against its own bundle.
public struct SidebarWorkspacePullRequestRows: View {
    let pullRequests: [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay]
    let foregroundColor: Color
    let fontScale: CGFloat
    let makesClickable: Bool
    let statusLabel: (SidebarPullRequestStatus) -> String
    let openTooltip: (_ title: String) -> String
    let onOpen: (URL) -> Void

    /// Creates the pull-request badge list.
    /// - Parameters:
    ///   - pullRequests: The badges to render, in order.
    ///   - foregroundColor: Foreground color for icon and text.
    ///   - fontScale: Multiplier applied to the base font size.
    ///   - makesClickable: Whether each row is a button that opens the PR.
    ///   - statusLabel: Maps a status to its localized word (e.g. "open").
    ///   - openTooltip: Builds the help tooltip from the row title.
    ///   - onOpen: Invoked with the PR URL when a clickable row is pressed.
    public init(
        pullRequests: [SidebarWorkspaceSnapshotBuilder.PullRequestDisplay],
        foregroundColor: Color,
        fontScale: CGFloat,
        makesClickable: Bool,
        statusLabel: @escaping (SidebarPullRequestStatus) -> String,
        openTooltip: @escaping (_ title: String) -> String,
        onOpen: @escaping (URL) -> Void
    ) {
        self.pullRequests = pullRequests
        self.foregroundColor = foregroundColor
        self.fontScale = fontScale
        self.makesClickable = makesClickable
        self.statusLabel = statusLabel
        self.openTooltip = openTooltip
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(pullRequests) { pullRequest in
                let pullRequestNumber = String(pullRequest.number)
                let pullRequestTitle = "\(pullRequest.label) #\(pullRequestNumber)"
                let rowContent = HStack(spacing: 4) {
                    PullRequestStatusIcon(
                        status: pullRequest.status,
                        color: foregroundColor,
                        fontScale: fontScale
                    )
                    Text(pullRequestTitle).underline(makesClickable).lineLimit(1).truncationMode(.tail)
                    Text(statusLabel(pullRequest.status)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10 * fontScale, weight: .semibold))
                .foregroundColor(foregroundColor)
                .opacity(pullRequest.isStale ? 0.5 : 1)
                if makesClickable {
                    Button(action: { onOpen(pullRequest.url) }) { rowContent }
                        .buttonStyle(.plain)
                        .tint(foregroundColor)
                        .safeHelp(openTooltip(pullRequestTitle))
                        .accessibilityIdentifier("SidebarPullRequestRow")
                } else {
                    rowContent.accessibilityElement(children: .combine).accessibilityIdentifier("SidebarPullRequestRow")
                }
            }
        }
    }
}
