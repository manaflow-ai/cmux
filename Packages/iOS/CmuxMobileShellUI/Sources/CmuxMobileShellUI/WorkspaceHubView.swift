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
    @State private var topologyAvailableSize = CGSize(width: 360, height: 240)

    private var projection: WorkspaceHubProjection {
        WorkspaceHubProjection(
            layout: layout,
            fallbackTerminals: workspace.terminals,
            supportsLayout: workspace.supportsWorkspaceLayout,
            chatCards: chatCards
        )
    }

    var body: some View {
        Group {
            if projection.panes.isEmpty {
                emptyState
            } else if projection.isDegraded {
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        degradedNotice
                        degradedCards
                    }
                    .padding(16)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    topologyMiniature
                        .padding(16)
                }
                .defaultScrollAnchor(.center)
                .scrollBounceBehavior(.basedOnSize)
                .onGeometryChange(for: CGSize.self) { geometry in
                    CGSize(
                        width: max(1, geometry.size.width - 32),
                        height: max(1, geometry.size.height - 32)
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

    private var topologyMiniature: some View {
        let size = topologyContentSize
        return ZStack(alignment: .topLeading) {
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
                .frame(width: paneWidth, height: paneHeight)
                .position(
                    x: size.width * (pane.frame.x + pane.frame.width / 2),
                    y: size.height * (pane.frame.y + pane.frame.height / 2)
                )
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var degradedCards: some View {
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

    private var topologyContentSize: CGSize {
        let smallestWidth = projection.panes.map(\.frame.width).filter { $0 > 0 }.min() ?? 1
        let smallestHeight = projection.panes.map(\.frame.height).filter { $0 > 0 }.min() ?? 1
        let aspectRatio: CGFloat = 1.5
        let fitted: CGSize
        if topologyAvailableSize.width / topologyAvailableSize.height > aspectRatio {
            fitted = CGSize(
                width: topologyAvailableSize.height * aspectRatio,
                height: topologyAvailableSize.height
            )
        } else {
            fitted = CGSize(
                width: topologyAvailableSize.width,
                height: topologyAvailableSize.width / aspectRatio
            )
        }
        let scale = max(
            1,
            48 / (fitted.width * CGFloat(smallestWidth)),
            48 / (fitted.height * CGFloat(smallestHeight))
        )
        return CGSize(width: fitted.width * scale, height: fitted.height * scale)
    }
}
