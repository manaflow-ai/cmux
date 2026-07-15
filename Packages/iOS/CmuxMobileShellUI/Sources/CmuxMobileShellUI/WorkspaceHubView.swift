import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The live miniature pane selector at workspace navigation level two.
struct WorkspaceHubView: View {
    let workspace: MobileWorkspacePreview
    let layout: MobileWorkspaceLayout?
    let connectionStatus: MobileMacConnectionStatus
    let previewUpdates: (String) -> AsyncStream<PreviewGridSnapshot>
    let browserPreviewUpdates: (String, MobileBrowserPreviewResolution) -> AsyncStream<MobileBrowserPreviewFrame>
    let chatCards: [PaneChatCardSnapshot]
    let transitionNamespace: Namespace.ID
    let selectPane: (WorkspaceHubPaneSnapshot) -> Void
    let backButtonConfiguration: WorkspaceBackButtonConfiguration?
    @State private var topologyAvailableSize = CGSize(width: 360, height: 640)

    /// The smallest height a pane cell may render at before the canvas grows
    /// vertically and the hub scrolls. Below this a terminal preview stops
    /// reading as content.
    private static let minimumPaneHeight: CGFloat = 150

    private func makeProjection(canvasAspect: Double?) -> WorkspaceHubProjection {
        WorkspaceHubProjection(
            layout: layout,
            fallbackTerminals: workspace.terminals,
            supportsLayout: workspace.supportsWorkspaceLayout,
            chatCards: chatCards,
            canvasAspect: canvasAspect
        )
    }

    /// Fits the split tree to the visible canvas, growing the canvas vertically
    /// (hub scrolls) only when a pane would fall below the minimum readable
    /// height. Growing changes the aspect, which can re-stack splits and change
    /// the smallest pane, so the fit re-runs a bounded number of times; each
    /// pass only makes the canvas taller, so it converges.
    private var resolvedTopology: (projection: WorkspaceHubProjection, size: CGSize) {
        var size = CGSize(
            width: max(1, topologyAvailableSize.width),
            height: max(1, topologyAvailableSize.height)
        )
        var projection = makeProjection(canvasAspect: size.width / size.height)
        for _ in 0..<3 {
            let smallestPaneHeight = projection.panes
                .map { $0.frame.height * size.height }
                .filter { $0 > 0 }
                .min() ?? size.height
            if smallestPaneHeight >= Self.minimumPaneHeight { break }
            size.height *= Self.minimumPaneHeight / smallestPaneHeight
            projection = makeProjection(canvasAspect: size.width / size.height)
        }
        return (projection, size)
    }

    var body: some View {
        let topology = resolvedTopology
        return Group {
            if topology.projection.panes.isEmpty {
                emptyState
            } else if topology.projection.isDegraded {
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        degradedNotice
                        degradedCards(topology.projection)
                    }
                    .padding(16)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ScrollView(.vertical) {
                    topologyMiniature(topology.projection, size: topology.size)
                        .padding(.horizontal, Self.outerInset)
                        .padding(.vertical, Self.outerInset)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onGeometryChange(for: CGSize.self) { geometry in
                    CGSize(
                        width: max(1, geometry.size.width - Self.outerInset * 2),
                        height: max(1, geometry.size.height - Self.outerInset * 2)
                    )
                } action: { availableSize in
                    topologyAvailableSize = availableSize
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(workspace.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(backButtonConfiguration != nil)
        .toolbar { hubToolbar }
        .overlay(alignment: .topTrailing) {
            MobileMacConnectionStatusPill(
                host: workspace.macDisplayName ?? "",
                status: connectionStatus
            )
            .padding(.top, 8)
            .padding(.trailing, 12)
        }
        .accessibilityIdentifier("MobileWorkspaceHub")
    }

    /// Half the visual gutter between adjacent panes; each pane insets by this
    /// on all sides so neighbors meet at a full gutter and the outer edge
    /// aligns with the outer inset.
    private static let paneGutter: CGFloat = 5
    private static let outerInset: CGFloat = 11

    private func topologyMiniature(_ projection: WorkspaceHubProjection, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(projection.panes) { pane in
                let paneWidth = size.width * pane.frame.width
                let paneHeight = size.height * pane.frame.height
                WorkspaceHubPaneView(
                    pane: pane,
                    connectionStatus: connectionStatus,
                    supportsBrowserPreview: workspace.supportsBrowserPreview,
                    previewUpdates: previewUpdates,
                    browserPreviewUpdates: browserPreviewUpdates,
                    transitionNamespace: transitionNamespace,
                    select: { selectPane(pane) }
                )
                .padding(Self.paneGutter)
                .frame(width: paneWidth, height: paneHeight)
                .position(
                    x: size.width * (pane.frame.x + pane.frame.width / 2),
                    y: size.height * (pane.frame.y + pane.frame.height / 2)
                )
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func degradedCards(_ projection: WorkspaceHubProjection) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(projection.panes) { pane in
                WorkspaceHubPaneView(
                    pane: pane,
                    connectionStatus: connectionStatus,
                    supportsBrowserPreview: workspace.supportsBrowserPreview,
                    previewUpdates: previewUpdates,
                    browserPreviewUpdates: browserPreviewUpdates,
                    transitionNamespace: transitionNamespace,
                    select: { selectPane(pane) }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            }
        }
    }

    private var degradedNotice: some View {
        Label(
            L10n.string(
                "mobile.workspaceHub.degraded",
                defaultValue: "Update cmux on this Mac to mirror its pane layout."
            ),
            systemImage: "rectangle.stack.badge.exclamationmark"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("MobileWorkspaceHubDegradedNotice")
    }

    private var emptyState: some View {
        ContentUnavailableView(
            L10n.string("mobile.workspaceHub.emptyTitle", defaultValue: "No Panes"),
            systemImage: "rectangle.split.2x1",
            description: Text(
                L10n.string(
                    "mobile.workspaceHub.emptyMessage",
                    defaultValue: "Open a terminal on your Mac to see it here."
                )
            )
        )
    }

    @ToolbarContentBuilder
    private var hubToolbar: some ToolbarContent {
        if let backButtonConfiguration {
            ToolbarItem(id: "workspace-hub-back", placement: .topBarLeading) {
                WorkspaceBackButton(
                    unreadCount: backButtonConfiguration.unreadCount,
                    badgeContrast: backButtonConfiguration.badgeContrast,
                    action: backButtonConfiguration.action
                )
            }
        }
    }

}
