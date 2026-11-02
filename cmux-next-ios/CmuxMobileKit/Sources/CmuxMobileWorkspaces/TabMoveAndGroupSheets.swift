#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

/// The pickers behind the tab menu's Move Tab to Workspace…, Add Tab to Group… and the saved
/// groups. The group's own actions are a pushed page (`TabGroupPage`).
struct TabMoveAndGroupSheets: ViewModifier {
    let source: WorkspaceTabsSource

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { source.movingTab }, set: { source.movingTab = $0 })) { tab in
                WorkspacePicker(tab: tab, workspaces: source.otherWorkspaces) { destination in
                    Task { await source.move(tab.id, to: destination) }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: Binding(get: { source.addingToGroupTab }, set: { source.addingToGroupTab = $0 })) { tab in
                TabGroupPicker(groups: source.groups(besides: tab)) { group in
                    Task { await source.editGroup(.add(group: group.id), tab.id) }
                }
                .presentationDetents([.medium])
            }
            .sheet(item: Binding(get: { source.savedGroupsChooser }, set: { source.savedGroupsChooser = $0 })) { chooser in
                SavedTabGroupPicker(chooser: chooser) { saved in
                    Task {
                        switch chooser.action {
                        case .reopen: await source.reopenSaved(saved, besides: chooser.tab.id)
                        case .delete: await source.deleteSaved(saved)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
    }
}

/// Move Tab to Workspace… (and Move Tab Group to Workspace…): the other workspaces on this Mac.
struct WorkspacePicker: View {
    let tab: WorkspaceTab
    let workspaces: [Workspace]
    var title = "Move Tab to Workspace"
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(workspaces) { workspace in
                Button {
                    dismiss()
                    pick(workspace.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.title).foregroundStyle(.primary)
                        if !workspace.directory.isEmpty {
                            Text(workspace.directory).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
                .accessibilityIdentifier("move-to.\(workspace.id)")
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Add Tab to Group…: the groups of this workspace.
struct TabGroupPicker: View {
    let groups: [WorkspaceTab.TabGroupRef]
    let pick: (WorkspaceTab.TabGroupRef) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(groups, id: \.id) { group in
                Button {
                    dismiss()
                    pick(group)
                } label: {
                    HStack {
                        Circle().fill(TabGroupChip.color(group.color)).frame(width: 10, height: 10)
                        Text(group.displayName).foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Add Tab to Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Reopen Saved Tab Group… / Delete Saved Tab Group…: the Mac's saved groups. A group that
/// is already open can't be reopened (the Mac refuses it too).
struct SavedTabGroupPicker: View {
    let chooser: WorkspaceTabsSource.SavedGroupsChooser
    let pick: (SavedTabGroup) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(chooser.groups) { group in
                let blocked = chooser.action == .reopen && group.isOpen
                Button(role: chooser.action == .delete ? .destructive : nil) {
                    dismiss()
                    pick(group)
                } label: {
                    HStack {
                        Circle().fill(TabGroupChip.color(group.color)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.displayName).foregroundStyle(chooser.action == .delete ? Color.red : .primary)
                            Text(group.isOpen ? "Open · \(group.summary)" : group.summary)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(blocked)
                .accessibilityIdentifier("saved-group.\(chooser.action.rawValue).\(group.id)")
            }
            .navigationTitle(chooser.action.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

#endif
