import SwiftUI

struct WorkspaceTasksView: View {
    let openTasks: [WorkspaceTask]
    let archivedTasks: [WorkspaceTask]
    @Binding var addDraft: String
    @Binding var insertionAfterTaskId: UUID?
    @Binding var insertionDraft: String
    let showsOpenAsTabButton: Bool
    let actions: WorkspaceTasksActions

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(taskAccent)
                .frame(height: 3)
                .accessibilityHidden(true)
            WorkspaceTasksHeaderView(
                openCount: openTasks.count,
                archivedCount: archivedTasks.count,
                showsOpenAsTabButton: showsOpenAsTabButton,
                openSurface: actions.openSurface
            )
            Divider()
                .opacity(0.52)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    WorkspaceTasksSectionView(
                        title: String(localized: "workspaceTasks.open.title", defaultValue: "Open"),
                        emptyText: String(localized: "workspaceTasks.empty.open", defaultValue: "No open tasks"),
                        tasks: openTasks,
                        canArchive: true,
                        addDraft: $addDraft,
                        insertionAfterTaskId: $insertionAfterTaskId,
                        insertionDraft: $insertionDraft,
                        actions: actions
                    )
                    WorkspaceTasksSectionView(
                        title: String(localized: "workspaceTasks.archived.title", defaultValue: "Archived"),
                        emptyText: String(localized: "workspaceTasks.empty.archived", defaultValue: "No archived tasks"),
                        tasks: archivedTasks,
                        canArchive: false,
                        addDraft: .constant(""),
                        insertionAfterTaskId: .constant(nil),
                        insertionDraft: .constant(""),
                        actions: actions
                    )
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var taskAccent: Color {
        Color(red: 0.86, green: 0.25, blue: 0.19)
    }
}
