import SwiftUI

// MARK: - ProjectSidebarHeader

/// Collapsible project row shown in the sidebar.
/// Displays the project name, directory, a chevron toggle, and the task count when collapsed.
struct ProjectSidebarHeader: View {
    @ObservedObject var project: Project
    @EnvironmentObject var tabManager: TabManager
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        HStack(spacing: 6) {
            // Chevron toggle
            Image(systemName: project.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        project.isExpanded.toggle()
                    }
                }

            // Project icon
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.8))

            if isEditing {
                TextField(
                    String(localized: "projectSidebar.renameField.placeholder", defaultValue: "Project name"),
                    text: $editText,
                    onCommit: {
                        commitRename()
                    }
                )
                .font(.system(size: 12, weight: .semibold))
                .textFieldStyle(.plain)
                .onExitCommand {
                    isEditing = false
                }
            } else {
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            // Task count badge when collapsed
            if !project.isExpanded {
                let liveCount = project.workspaceIds.filter { wsId in
                    tabManager.tabs.contains { $0.id == wsId }
                }.count
                Text("\(liveCount)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                    )
            }

            // Add task button on hover
            if isHovering {
                Button(action: {
                    tabManager.addTask(to: project)
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "projectSidebar.addTask.tooltip", defaultValue: "New task"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                project.isExpanded.toggle()
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                startEditing()
            }
        )
        .contextMenu {
            Button(String(localized: "projectSidebar.contextMenu.newTask", defaultValue: "New task")) {
                tabManager.addTask(to: project)
            }
            Divider()
            Button(String(localized: "projectSidebar.contextMenu.rename", defaultValue: "Rename")) {
                startEditing()
            }
            Divider()
            Button(String(localized: "projectSidebar.contextMenu.delete", defaultValue: "Delete project"), role: .destructive) {
                tabManager.deleteProject(project)
            }
        }
    }

    private func startEditing() {
        editText = project.name
        isEditing = true
    }

    private func commitRename() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            project.name = trimmed
        }
        isEditing = false
    }
}

// MARK: - ProjectTaskRow

/// A single task (workspace) row displayed under a project in the sidebar.
struct ProjectTaskRow: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var tabManager: TabManager
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        HStack(spacing: 6) {
            // Task icon
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))

            if isEditing {
                TextField(
                    String(localized: "projectSidebar.taskRenameField.placeholder", defaultValue: "Task name"),
                    text: $editText,
                    onCommit: {
                        commitRename()
                    }
                )
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .onExitCommand {
                    isEditing = false
                }
            } else {
                Text(workspace.customTitle ?? workspace.title)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            // Active indicator (green dot)
            if workspace.writers.contains(where: { $0.isActive }) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }

            // Close button on hover
            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .padding(.leading, 14)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(rowBackground)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                startEditing()
            }
        )
        .contextMenu {
            Button(String(localized: "projectSidebar.task.contextMenu.rename", defaultValue: "Rename")) {
                startEditing()
            }
            Divider()
            Button(String(localized: "projectSidebar.task.contextMenu.delete", defaultValue: "Delete"), role: .destructive) {
                onDelete()
            }
        }
    }

    private var rowBackground: Color {
        if isActive {
            return Color.accentColor.opacity(0.15)
        }
        if isHovering {
            return Color.primary.opacity(0.04)
        }
        return Color.clear
    }

    private func startEditing() {
        editText = workspace.customTitle ?? workspace.title
        isEditing = true
    }

    private func commitRename() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tabManager.setCustomTitle(tabId: workspace.id, title: trimmed)
            if workspace.writers.count == 1, let writer = workspace.writers.first {
                workspace.renameWriter(writer, to: trimmed)
            }
        }
        isEditing = false
    }
}

// MARK: - ProjectTasksList

/// The list of task-workspaces nested under a single project in the sidebar.
struct ProjectTasksList: View {
    @ObservedObject var project: Project
    @EnvironmentObject var tabManager: TabManager

    var body: some View {
        VStack(spacing: 1) {
            ForEach(liveWorkspaces) { workspace in
                ProjectTaskRow(
                    workspace: workspace,
                    isActive: tabManager.selectedTabId == workspace.id,
                    onSelect: {
                        tabManager.selectedTabId = workspace.id
                    },
                    onDelete: {
                        tabManager.removeTask(workspaceId: workspace.id, from: project)
                    }
                )
            }

            // "+ New task" button
            Button(action: {
                tabManager.addTask(to: project)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .medium))
                    Text(String(localized: "projectSidebar.newTask", defaultValue: "New task"))
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .padding(.leading, 14)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }

    /// Workspaces that still exist in tabManager, in the order stored by the project.
    private var liveWorkspaces: [Workspace] {
        project.workspaceIds.compactMap { wsId in
            tabManager.tabs.first { $0.id == wsId }
        }
    }
}

// MARK: - SidebarProjectSection

/// Renders a single project group: collapsible header + task list when expanded.
struct SidebarProjectSection: View {
    @ObservedObject var project: Project

    var body: some View {
        VStack(spacing: 0) {
            ProjectSidebarHeader(project: project)

            if project.isExpanded {
                ProjectTasksList(project: project)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Legacy compatibility aliases

// Keep SidebarWritersSection available for any remaining references.
// It now renders nothing since writer lists are no longer shown nested
// under workspaces in the sidebar — tasks are shown under projects instead.
struct SidebarWritersSection: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        EmptyView()
    }
}
