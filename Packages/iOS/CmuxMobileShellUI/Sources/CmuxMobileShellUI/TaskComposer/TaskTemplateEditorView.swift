#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TaskTemplateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editingTemplate: MobileTaskTemplate?
    @State private var isAddingTemplate = false

    let templates: [MobileTaskTemplate]
    let addTemplate: (MobileTaskTemplate) -> Void
    let updateTemplate: (MobileTaskTemplate) -> Void
    let deleteTemplates: (IndexSet) -> Void
    let refresh: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(templates) { template in
                        Button {
                            editingTemplate = template
                        } label: {
                            HStack(spacing: 12) {
                                TaskTemplateIcon(value: template.icon)
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name)
                                        .foregroundStyle(.primary)
                                    Text(
                                        template.isPlainShell
                                            ? L10n.string(
                                                "mobile.taskComposer.template.plainShell",
                                                defaultValue: "Plain shell"
                                            )
                                            : template.command
                                    )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        deleteTemplates(offsets)
                        refresh()
                    }
                } footer: {
                    Text(L10n.string(
                        "mobile.taskComposer.template.hint",
                        defaultValue: "The task prompt is available to the command as $CMUX_TASK_PROMPT. Example: claude -- \"$CMUX_TASK_PROMPT\""
                    ))
                }
            }
            .navigationTitle(L10n.string("mobile.taskComposer.templates.title", defaultValue: "Task Templates"))
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingTemplate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.string("mobile.taskComposer.template.add", defaultValue: "Add Template"))
                }
            }
            .sheet(item: $editingTemplate) { template in
                TaskTemplateFormView(template: template) { updated in
                    updateTemplate(updated)
                    refresh()
                }
            }
            .sheet(isPresented: $isAddingTemplate) {
                TaskTemplateFormView(template: nil) { template in
                    addTemplate(template)
                    refresh()
                }
            }
        }
    }
}
#endif
