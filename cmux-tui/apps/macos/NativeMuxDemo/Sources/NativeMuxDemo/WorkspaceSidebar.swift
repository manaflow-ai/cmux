import SwiftUI

struct WorkspaceSidebar: View {
    let model: FrontendModel
    let snapshot: ResourceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("sidebar.workspaces", "WORKSPACES"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: model.createWorkspace) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help(L10n.text("sidebar.new_workspace", "New workspace"))
            }
            .padding(.horizontal, 13)
            .padding(.top, 38)
            .padding(.bottom, 9)

            ScrollView {
                LazyVStack(spacing: 3) {
                    let selectedWorkspaceID = model.selectedWorkspace?.id
                    ForEach(snapshot.orderedWorkspaces) { workspace in
                        WorkspaceSidebarRow(
                            workspace: workspace,
                            selectedWorkspaceID: selectedWorkspaceID,
                            spaceCount: snapshot.screenCount(in: workspace.id),
                            onSelect: { model.selectWorkspace(workspace) },
                            onClose: { model.closeWorkspace(workspace) }
                        )
                        .equatable()
                    }
                }
                .padding(.horizontal, 7)
            }

            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text(L10n.text("transport.ready", "Iroh · local libghostty"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
    }

}

private struct WorkspaceSidebarRow: View, Equatable {
    let workspace: WorkspaceSnapshot
    let selectedWorkspaceID: String?
    let spaceCount: Int
    let onSelect: () -> Void
    let onClose: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspace.id == rhs.workspace.id
            && lhs.selectedWorkspaceID == rhs.selectedWorkspaceID
            && lhs.workspace.name == rhs.workspace.name
            && lhs.workspace.index == rhs.workspace.index
            && lhs.spaceCount == rhs.spaceCount
    }

    var body: some View {
        let selected = workspace.id == selectedWorkspaceID
        return Button(action: onSelect) {
            HStack(spacing: 9) {
                Image(systemName: selected ? "rectangle.stack.fill" : "rectangle.stack")
                    .foregroundStyle(selected ? .cyan : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.name.isEmpty
                        ? L10n.format("workspace.number", "workspace %d", workspace.index + 1)
                        : workspace.name)
                        .lineLimit(1)
                    Text(L10n.format(
                        spaceCount == 1 ? "spaces.count.one" : "spaces.count.other",
                        spaceCount == 1 ? "%d space" : "%d spaces",
                        spaceCount
                    ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(.rect)
            .background(
                selected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: .rect(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L10n.text("workspace.close", "Close workspace"), role: .destructive) {
                onClose()
            }
        }
    }
}
