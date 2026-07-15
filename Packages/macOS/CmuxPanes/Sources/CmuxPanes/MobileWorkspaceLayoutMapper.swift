public import Bonsplit
public import CMUXMobileCore

/// Projects a Bonsplit tree into the shared mobile workspace-layout DTOs.
public struct MobileWorkspaceLayoutMapper: Sendable {
    /// Creates a stateless workspace-layout mapper.
    public init() {}

    /// Maps a Bonsplit snapshot while preserving its split ratios, pane ids, and tab order.
    ///
    /// Tabs absent from `tabsBySurfaceID` are omitted. This lets the app exclude
    /// panel kinds the v1 mobile protocol cannot represent without distorting the
    /// pane tree itself.
    /// - Parameters:
    ///   - workspaceID: The stable workspace identifier.
    ///   - tree: The authoritative Bonsplit tree snapshot.
    ///   - activePaneID: The currently focused Bonsplit pane identifier.
    ///   - tabsBySurfaceID: Mobile tab metadata keyed by Bonsplit surface id.
    /// - Returns: A shared mobile workspace layout with unit-coordinate pane frames.
    public func layout(
        workspaceID: String,
        tree: ExternalTreeNode,
        activePaneID: String?,
        tabsBySurfaceID: [String: MobileWorkspaceTab]
    ) -> MobileWorkspaceLayout {
        MobileWorkspaceLayout(
            workspaceID: workspaceID,
            root: node(
                from: tree,
                frame: .unit,
                tabsBySurfaceID: tabsBySurfaceID
            ),
            activePaneID: activePaneID
        )
    }

    private func node(
        from node: ExternalTreeNode,
        frame: MobileWorkspacePaneFrame,
        tabsBySurfaceID: [String: MobileWorkspaceTab]
    ) -> MobileWorkspaceLayoutNode {
        switch node {
        case let .pane(pane):
            let tabs = pane.tabs.compactMap { externalTab -> MobileWorkspaceTab? in
                guard var tab = tabsBySurfaceID[externalTab.id] else { return nil }
                tab.isActive = externalTab.id == pane.selectedTabId
                return tab
            }
            return .pane(MobileWorkspacePane(id: pane.id, frame: frame, tabs: tabs))
        case let .split(split):
            let orientation: MobileWorkspaceSplitOrientation =
                split.orientation.lowercased() == "vertical" ? .vertical : .horizontal
            let ratio = min(max(split.dividerPosition, 0), 1)
            let frames = childFrames(frame: frame, orientation: orientation, ratio: ratio)
            return .split(MobileWorkspaceSplit(
                id: split.id,
                orientation: orientation,
                ratio: ratio,
                first: self.node(
                    from: split.first,
                    frame: frames.first,
                    tabsBySurfaceID: tabsBySurfaceID
                ),
                second: self.node(
                    from: split.second,
                    frame: frames.second,
                    tabsBySurfaceID: tabsBySurfaceID
                )
            ))
        }
    }

    private func childFrames(
        frame: MobileWorkspacePaneFrame,
        orientation: MobileWorkspaceSplitOrientation,
        ratio: Double
    ) -> (first: MobileWorkspacePaneFrame, second: MobileWorkspacePaneFrame) {
        switch orientation {
        case .horizontal:
            let firstWidth = frame.width * ratio
            return (
                MobileWorkspacePaneFrame(
                    x: frame.x,
                    y: frame.y,
                    width: firstWidth,
                    height: frame.height
                ),
                MobileWorkspacePaneFrame(
                    x: frame.x + firstWidth,
                    y: frame.y,
                    width: frame.width - firstWidth,
                    height: frame.height
                )
            )
        case .vertical:
            let firstHeight = frame.height * ratio
            return (
                MobileWorkspacePaneFrame(
                    x: frame.x,
                    y: frame.y,
                    width: frame.width,
                    height: firstHeight
                ),
                MobileWorkspacePaneFrame(
                    x: frame.x,
                    y: frame.y + firstHeight,
                    width: frame.width,
                    height: frame.height - firstHeight
                )
            )
        }
    }
}
