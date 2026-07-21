public import Bonsplit
public import CMUXMobileCore

/// Converts bonsplit's external tree into the shared mobile pane-layout DTO.
public struct MobileWorkspaceLayoutSerializer: Sendable {
    /// Creates a stateless workspace-layout serializer.
    public init() {}

    /// Builds the shared pane-layout snapshot from a bonsplit tree.
    ///
    /// - Parameters:
    ///   - tree: The source bonsplit tree.
    ///   - version: The workspace's pane-layout revision.
    ///   - focusedPaneID: The focused pane identifier, when any.
    ///   - surfacesByTabID: Panel metadata keyed by bonsplit tab identifier.
    /// - Returns: A complete shared pane-layout snapshot.
    public func layout(
        tree: ExternalTreeNode,
        version: Int,
        focusedPaneID: String?,
        surfacesByTabID: [String: MobileWorkspaceLayoutSurfaceMetadata]
    ) -> MobileWorkspaceLayout {
        MobileWorkspaceLayout(
            version: version,
            focusedPaneID: focusedPaneID,
            root: layoutNode(tree, surfacesByTabID: surfacesByTabID)
        )
    }

    /// Returns every bonsplit tab in pane-spatial and then tab order.
    ///
    /// - Parameter tree: The source bonsplit tree.
    /// - Returns: Tabs in depth-first pane order without recursive array copies.
    public func tabs(in tree: ExternalTreeNode) -> [ExternalTab] {
        var result: [ExternalTab] = []
        appendTabs(in: tree, to: &result)
        return result
    }

    /// Returns pane identities, tab ordering, and selection in spatial order.
    ///
    /// - Parameter tree: The source bonsplit tree.
    /// - Returns: Pane topology in depth-first spatial order.
    public func paneTopology(in tree: ExternalTreeNode) -> [MobileWorkspacePaneTopology] {
        var result: [MobileWorkspacePaneTopology] = []
        appendPaneTopology(in: tree, to: &result)
        return result
    }

    private func appendTabs(in node: ExternalTreeNode, to result: inout [ExternalTab]) {
        switch node {
        case let .pane(pane):
            result.append(contentsOf: pane.tabs)
        case let .split(split):
            appendTabs(in: split.first, to: &result)
            appendTabs(in: split.second, to: &result)
        }
    }

    private func appendPaneTopology(
        in node: ExternalTreeNode,
        to result: inout [MobileWorkspacePaneTopology]
    ) {
        switch node {
        case let .pane(pane):
            result.append(
                MobileWorkspacePaneTopology(
                    id: pane.id,
                    surfaceIDs: pane.tabs.map(\.id),
                    selectedSurfaceID: pane.selectedTabId
                )
            )
        case let .split(split):
            appendPaneTopology(in: split.first, to: &result)
            appendPaneTopology(in: split.second, to: &result)
        }
    }

    private func layoutNode(
        _ node: ExternalTreeNode,
        surfacesByTabID: [String: MobileWorkspaceLayoutSurfaceMetadata]
    ) -> MobileWorkspaceLayoutNode {
        switch node {
        case let .pane(pane):
            let surfaces = pane.tabs.map { tab in
                let metadata = surfacesByTabID[tab.id]
                    ?? MobileWorkspaceLayoutSurfaceMetadata(
                        id: tab.id,
                        type: "terminal",
                        title: tab.title
                    )
                return MobileWorkspaceLayoutSurface(
                    id: metadata.id,
                    type: metadata.type,
                    title: metadata.title
                )
            }
            let selectedSurfaceID = pane.selectedTabId.map { tabID in
                surfacesByTabID[tabID]?.id ?? tabID
            }
            return .pane(
                MobileWorkspaceLayoutPane(
                    id: pane.id,
                    selectedSurfaceID: selectedSurfaceID,
                    surfaces: surfaces
                )
            )
        case let .split(split):
            let orientation: MobileWorkspaceLayoutOrientation
            switch split.orientation {
            case "vertical":
                orientation = .vertical
            case "horizontal":
                orientation = .horizontal
            default:
                assertionFailure("Bonsplit emitted an unsupported orientation: \(split.orientation)")
                orientation = .horizontal
            }
            return .split(
                MobileWorkspaceLayoutSplit(
                    id: split.id,
                    orientation: orientation,
                    ratio: split.dividerPosition,
                    first: layoutNode(split.first, surfacesByTabID: surfacesByTabID),
                    second: layoutNode(split.second, surfacesByTabID: surfacesByTabID)
                )
            )
        }
    }
}
