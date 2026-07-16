import Foundation
public import CMUXMobileCore
public import CmuxMobileShellModel

extension MobileWorkspacePaneLayout {
    /// Build the client layout model from the wire layout node.
    /// - Parameter remote: The decoded `layout` payload for one workspace.
    public init(remote: MobileWorkspaceLayoutNode) {
        self.init(root: Node(remote: remote))
    }
}

extension MobileWorkspacePaneLayout.Node {
    /// Map one wire node (split or pane) onto the client model.
    /// - Parameter remote: The decoded wire node.
    init(remote: MobileWorkspaceLayoutNode) {
        switch remote {
        case let .split(orientation, ratio, first, second):
            self = .split(
                orientation: MobileWorkspacePaneLayout.Orientation(remote: orientation),
                ratio: ratio,
                first: Self(remote: first),
                second: Self(remote: second)
            )
        case let .pane(paneID, tabs, selectedTabID):
            self = .pane(
                MobileWorkspacePaneLayout.Pane(
                    id: .init(rawValue: paneID),
                    tabs: tabs.map { MobileWorkspacePaneLayout.Tab(remote: $0) },
                    selectedTabID: selectedTabID.map { .init(rawValue: $0) }
                )
            )
        }
    }
}

extension MobileWorkspacePaneLayout.Orientation {
    /// Map the wire orientation onto the client model.
    /// - Parameter remote: The decoded wire orientation.
    init(remote: MobileWorkspaceLayoutNode.Orientation) {
        switch remote {
        case .horizontal: self = .horizontal
        case .vertical: self = .vertical
        }
    }
}

extension MobileWorkspacePaneLayout.Tab {
    /// Map one wire tab onto the client model. Unknown kinds degrade to
    /// `.other` so a newer Mac never breaks an older phone.
    /// - Parameter remote: The decoded wire tab.
    init(remote: MobileWorkspaceLayoutTab) {
        self.init(
            id: .init(rawValue: remote.id),
            kind: Kind(rawValue: remote.kind) ?? .other,
            title: remote.title
        )
    }
}
