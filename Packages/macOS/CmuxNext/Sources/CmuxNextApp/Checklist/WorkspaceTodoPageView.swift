import CmuxNextDaemon
import CmuxNextDesign
import SwiftUI
import CmuxNextTasks

/// The Todo page: a field that adds an item, then the workspace's checklist.
struct WorkspaceTodoPageView: View {
    @Bindable var model: WorkspaceTodoPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.shown == nil {
                Text(WorkspaceChecklistStrings.noWorkspace).foregroundStyle(.secondary)
            } else {
                TextField(WorkspaceChecklistStrings.addPlaceholder, text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .focusEffectDisabled()
                    .onSubmit { model.submitDraft() }
                let items = model.items
                if items.isEmpty {
                    Text(WorkspaceChecklistStrings.empty).foregroundStyle(.secondary)
                } else {
                    let editing = model.editing
                    let actions = rowActions
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(items) { item in
                                WorkspaceTodoRow(item: item, isEditing: editing == item.id, actions: actions)
                            }
                        }
                        .thinScrollers()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: 640, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var rowActions: WorkspaceTodoRowActions {
        let model = model
        return WorkspaceTodoRowActions(
            toggle: { model.toggle($0) },
            setState: { model.setState($0, $1) },
            beginEdit: { model.editing = $0 },
            commitEdit: { item, text in
                model.editing = nil
                model.edit(item, text: text)
            },
            cancelEdit: { model.editing = nil },
            attachImages: { model.attachImages($0) },
            remove: { model.remove($0) })
    }
}
