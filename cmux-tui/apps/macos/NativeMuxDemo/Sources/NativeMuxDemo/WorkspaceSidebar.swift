import SwiftUI

struct WorkspaceSidebar: View {
    @Environment(\.localization) private var localization
    let model: FrontendModel
    let snapshot: ResourceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(localization.text("sidebar.workspaces", "WORKSPACES"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: model.createWorkspace) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help(localization.text("sidebar.new_workspace", "New workspace"))
            }
            .padding(.horizontal, 13)
            .padding(.top, 38)
            .padding(.bottom, 9)

            ScrollView {
                LazyVStack(spacing: 3) {
                    let selectedWorkspaceID = model.selectedWorkspace?.id
                    ForEach(snapshot.orderedWorkspaces) { workspace in
                        let spaceCount = snapshot.screenCount(in: workspace.id)
                        WorkspaceSidebarRow(
                            workspace: workspace,
                            isSelected: workspace.id == selectedWorkspaceID,
                            spaceCountLabel: localization.format(
                                spaceCount == 1 ? "spaces.count.one" : "spaces.count.other",
                                spaceCount == 1 ? "%d space" : "%d spaces",
                                spaceCount
                            ),
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
                Text(localization.text("transport.ready", "Iroh · local libghostty"))
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
    @Environment(\.localization) private var localization
    let workspace: WorkspaceSnapshot
    let isSelected: Bool
    let spaceCountLabel: String
    let onSelect: () -> Void
    let onClose: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspace.id == rhs.workspace.id
            && lhs.isSelected == rhs.isSelected
            && lhs.workspace.name == rhs.workspace.name
            && lhs.workspace.index == rhs.workspace.index
            && lhs.spaceCountLabel == rhs.spaceCountLabel
    }

    var body: some View {
        return Button(action: onSelect) {
            HStack(spacing: 9) {
                Image(systemName: isSelected ? "rectangle.stack.fill" : "rectangle.stack")
                    .foregroundStyle(isSelected ? .cyan : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.displayName(localization: localization))
                        .lineLimit(1)
                    Text(spaceCountLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .contentShape(.rect)
            .background(
                isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: .rect(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(localization.text("workspace.close", "Close workspace"), role: .destructive) {
                onClose()
            }
        }
    }
}
