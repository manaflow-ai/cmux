import CmuxExtensionKit
import SwiftUI

public struct CMUXSampleSidebarView: View {
    private let snapshot: CMUXSidebarSnapshot
    private let onAction: (CMUXSidebarAction) -> Void

    public init(
        snapshot: CMUXSidebarSnapshot,
        onAction: @escaping (CMUXSidebarAction) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.onAction = onAction
    }

    public var body: some View {
        List(snapshot.workspaces) { workspace in
            CMUXSampleWorkspaceRow(
                workspace: workspace,
                isSelected: workspace.id == snapshot.selectedWorkspaceID,
                onSelect: {
                    onAction(.selectWorkspace(workspace.id))
                }
            )
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220, idealWidth: 260)
    }
}
