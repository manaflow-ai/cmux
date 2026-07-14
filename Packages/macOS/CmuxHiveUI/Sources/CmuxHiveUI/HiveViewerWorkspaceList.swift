public import CmuxHive
public import SwiftUI

/// The viewer sidebar: the remote Mac's workspaces with their terminals.
///
/// Receives immutable value snapshots plus a selection binding only
/// (snapshot-boundary rule: nothing below the `List` observes a store).
public struct HiveViewerWorkspaceList: View {
    private let workspaces: [HiveRemoteWorkspace]
    @Binding private var selection: HiveViewerSelection?

    /// Creates the sidebar list.
    public init(workspaces: [HiveRemoteWorkspace], selection: Binding<HiveViewerSelection?>) {
        self.workspaces = workspaces
        _selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(workspaces) { workspace in
                Section {
                    ForEach(workspace.terminals) { terminal in
                        Label(terminal.title, systemImage: "terminal")
                            .lineLimit(1)
                            .tag(HiveViewerSelection(workspaceID: workspace.id, terminalID: terminal.id))
                    }
                } header: {
                    Text(workspace.title)
                        .lineLimit(1)
                }
            }
        }
        .overlay {
            if workspaces.isEmpty {
                Text(String(
                    localized: "hive.viewer.workspaces.empty",
                    defaultValue: "No workspaces yet."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
