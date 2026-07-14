public import CMUXMobileCore

/// A pure projection from authoritative workspace topology to hub pane cards.
public struct WorkspaceHubProjection: Equatable, Sendable {
    /// Pane cards in recursive visual order.
    public let panes: [WorkspaceHubPaneSnapshot]
    /// Whether the projection uses the legacy flat-terminal fallback.
    public let isDegraded: Bool

    /// Creates a hub projection for a workspace snapshot.
    ///
    /// A capable Mac uses its recursive split ratios. Until its first layout
    /// arrives, the hub maps every flat terminal to a full-width card so it never
    /// renders blank. Only a Mac without layout support is marked as degraded.
    /// - Parameters:
    ///   - layout: The latest authoritative layout, when available.
    ///   - fallbackTerminals: The workspace's legacy flat terminal list.
    ///   - supportsLayout: Whether this workspace's owning Mac advertised layout support.
    public init(
        layout: MobileWorkspaceLayout?,
        fallbackTerminals: [MobileTerminalPreview],
        supportsLayout: Bool
    ) {
        guard supportsLayout, let layout else {
            panes = Self.fallbackPanes(from: fallbackTerminals)
            isDegraded = !supportsLayout
            return
        }
        panes = Self.layoutPanes(
            node: layout.root,
            frame: .unit,
            activePaneID: layout.activePaneID
        )
        isDegraded = false
    }

    private static func layoutPanes(
        node: MobileWorkspaceLayoutNode,
        frame: WorkspaceHubPaneFrame,
        activePaneID: String?
    ) -> [WorkspaceHubPaneSnapshot] {
        switch node {
        case .pane(let pane):
            let activeTab = pane.tabs.first(where: \.isActive) ?? pane.tabs.first
            return [WorkspaceHubPaneSnapshot(
                id: pane.id,
                frame: frame,
                activeSurfaceID: activeTab?.id,
                activeTitle: activeTab?.name ?? "",
                tabCount: pane.tabs.count,
                agentStatus: activeTab?.agentStatus,
                hasUnread: activeTab?.hasUnread ?? false,
                focusState: WorkspaceHubFocusState(paneID: pane.id, activePaneID: activePaneID),
                isFallback: false
            )]
        case .split(let split):
            let ratio = min(1, max(0, split.ratio))
            let childFrames = splitFrames(frame: frame, orientation: split.orientation, ratio: ratio)
            return layoutPanes(node: split.first, frame: childFrames.first, activePaneID: activePaneID)
                + layoutPanes(node: split.second, frame: childFrames.second, activePaneID: activePaneID)
        }
    }

    private static func splitFrames(
        frame: WorkspaceHubPaneFrame,
        orientation: MobileWorkspaceSplitOrientation,
        ratio: Double
    ) -> (first: WorkspaceHubPaneFrame, second: WorkspaceHubPaneFrame) {
        switch orientation {
        case .horizontal:
            let firstWidth = frame.width * ratio
            return (
                WorkspaceHubPaneFrame(x: frame.x, y: frame.y, width: firstWidth, height: frame.height),
                WorkspaceHubPaneFrame(
                    x: frame.x + firstWidth,
                    y: frame.y,
                    width: frame.width - firstWidth,
                    height: frame.height
                )
            )
        case .vertical:
            let firstHeight = frame.height * ratio
            return (
                WorkspaceHubPaneFrame(x: frame.x, y: frame.y, width: frame.width, height: firstHeight),
                WorkspaceHubPaneFrame(
                    x: frame.x,
                    y: frame.y + firstHeight,
                    width: frame.width,
                    height: frame.height - firstHeight
                )
            )
        }
    }

    private static func fallbackPanes(
        from terminals: [MobileTerminalPreview]
    ) -> [WorkspaceHubPaneSnapshot] {
        let count = max(1, terminals.count)
        return terminals.enumerated().map { index, terminal in
            WorkspaceHubPaneSnapshot(
                id: "fallback:\(terminal.id.rawValue)",
                frame: WorkspaceHubPaneFrame(
                    x: 0,
                    y: Double(index) / Double(count),
                    width: 1,
                    height: 1 / Double(count)
                ),
                activeSurfaceID: terminal.id.rawValue,
                activeTitle: terminal.name,
                tabCount: 1,
                agentStatus: nil,
                hasUnread: false,
                focusState: WorkspaceHubFocusState(isFocused: terminal.isFocused),
                isFallback: true
            )
        }
    }
}
