import CmuxExtensionKit
import SwiftUI

struct TabsVisibleSidebarView: View {
    var extensionModel: TabsVisibleSidebarExtension

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "tabsVisible.title", defaultValue: "Workspaces"))
                    .font(.system(size: 14, weight: .semibold))

                if let errorText = extensionModel.errorText {
                    status(errorText)
                }

                if let snapshot = extensionModel.snapshot {
                    workspaceList(snapshot)
                } else {
                    waitingState
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func workspaceList(_ snapshot: CmuxSidebarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if snapshot.workspaces.isEmpty {
                Text(String(localized: "tabsVisible.noWorkspaces", defaultValue: "No workspaces shared by cmux"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.workspaces) { workspace in
                    workspaceDisclosure(workspace, selectedWorkspaceID: snapshot.selectedWorkspaceID)
                }
            }
        }
    }

    private func workspaceDisclosure(
        _ workspace: CmuxSidebarWorkspace,
        selectedWorkspaceID: UUID?
    ) -> some View {
        let isExpanded = Binding(
            get: { extensionModel.expandedWorkspaceIDs.contains(workspace.id) },
            set: { isExpanded in
                if isExpanded {
                    extensionModel.expandedWorkspaceIDs.insert(workspace.id)
                } else {
                    extensionModel.expandedWorkspaceIDs.remove(workspace.id)
                }
            }
        )

        return DisclosureGroup(isExpanded: isExpanded) {
            surfacesList(workspace)
                .padding(.leading, 18)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: workspace.id == selectedWorkspaceID ? "target" : "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(workspace.id == selectedWorkspaceID ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let detail = workspace.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Text("\(workspace.surfaces.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                extensionModel.selectWorkspace(workspace.id)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            workspace.id == selectedWorkspaceID ? Color.blue.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    private func surfacesList(_ workspace: CmuxSidebarWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if workspace.surfaces.isEmpty {
                Text(String(localized: "tabsVisible.noSurfaces", defaultValue: "No shared tabs"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(workspace.surfaces) { surface in
                    Button {
                        extensionModel.selectSurface(workspaceID: workspace.id, surfaceID: surface.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: iconName(for: surface.kind))
                                .font(.system(size: 10, weight: .semibold))
                                .frame(width: 14, height: 14)
                                .foregroundStyle(surface.isFocused ? .blue : .secondary)
                            Text(surface.title)
                                .font(.system(size: 11, weight: surface.isFocused ? .semibold : .regular))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if surface.unreadCount > 0 {
                                Text("\(surface.unreadCount)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        surface.isFocused ? Color.blue.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                }
            }
        }
    }

    private var waitingState: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "tabsVisible.waiting", defaultValue: "Waiting for cmux"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func iconName(for kind: CmuxSidebarSurfaceKind) -> String {
        switch kind {
        case .terminal:
            return "terminal"
        case .browser:
            return "globe"
        case .markdown:
            return "doc.text"
        case .filePreview:
            return "doc"
        case .rightSidebarTool:
            return "sidebar.right"
        case .project:
            return "folder"
        case .unknown:
            return "rectangle"
        }
    }
}
