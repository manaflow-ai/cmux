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
            WorkspaceTasksHeaderView(
                openCount: openTasks.count,
                archivedCount: archivedTasks.count,
                showsOpenAsTabButton: showsOpenAsTabButton,
                openSurface: actions.openSurface
            )
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                .padding(16)
            }
        }
    }
}
