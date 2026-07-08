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
                                taskTemplateIcon(template.icon)
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name)
                                        .foregroundStyle(.primary)
                                    Text(template.command.isEmpty ? L10n.string("mobile.taskComposer.template.plainShell", defaultValue: "Plain shell") : template.command)
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
                    Text(L10n.string("mobile.taskComposer.template.hint", defaultValue: "{prompt} and $CMUX_TASK_PROMPT receive the task prompt."))
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

private struct TaskTemplateFormView: View {
    @Environment(\.dismiss) private var dismiss
    private let existing: MobileTaskTemplate?
    private let onSave: (MobileTaskTemplate) -> Void

    @State private var name: String
    @State private var icon: String
    @State private var command: String
    @State private var defaultDirectory: String

    init(template: MobileTaskTemplate?, onSave: @escaping (MobileTaskTemplate) -> Void) {
        self.existing = template
        self.onSave = onSave
        _name = State(initialValue: template?.name ?? "")
        _icon = State(initialValue: template?.icon ?? "terminal")
        _command = State(initialValue: template?.command ?? "")
        _defaultDirectory = State(initialValue: template?.defaultDirectory ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.string("mobile.taskComposer.template.details", defaultValue: "Details")) {
                    TextField(L10n.string("mobile.taskComposer.template.name", defaultValue: "Name"), text: $name)
                    TaskTemplateIconPicker(selection: $icon)
                }
                Section(L10n.string("mobile.taskComposer.template.command", defaultValue: "Command")) {
                    TextField(
                        L10n.string("mobile.taskComposer.template.commandPlaceholder", defaultValue: "claude {prompt}"),
                        text: $command,
                        axis: .vertical
                    )
                    .lineLimit(3...10)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Text(L10n.string("mobile.taskComposer.template.hint", defaultValue: "{prompt} and $CMUX_TASK_PROMPT receive the task prompt."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(L10n.string("mobile.taskComposer.directory", defaultValue: "Directory")) {
                    TextField("~", text: $defaultDirectory)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(existing == nil ? L10n.string("mobile.taskComposer.template.addTitle", defaultValue: "Add Template") : L10n.string("mobile.taskComposer.template.editTitle", defaultValue: "Edit Template"))
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.save", defaultValue: "Save")) {
                        save()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let directory = defaultDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(MobileTaskTemplate(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            icon: icon.trimmingCharacters(in: .whitespacesAndNewlines),
            command: command,
            defaultDirectory: directory.isEmpty ? nil : directory
        ))
        dismiss()
    }
}
#endif
