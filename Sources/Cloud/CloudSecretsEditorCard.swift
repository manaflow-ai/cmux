import CmuxCloud
import CmuxFoundation
import SwiftUI

/// The inline add/replace card: name, a secure value field, where it
/// applies, and Cancel/Save on Esc/Return. The value is never shown, and the
/// field is emptied when the card closes.
struct CloudSecretsEditorCard: View {
    @Bindable var model: CloudSecretsSheetModel
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case name
        case value
        case project
    }

    var body: some View {
        if let editor = model.editor {
            VStack(alignment: .leading, spacing: 10) {
                Text(title(editor))
                    .cmuxFont(size: 13, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        rowLabel(String(localized: "cloudSecrets.editor.name", defaultValue: "Name"))
                        TextField(
                            String(localized: "cloudSecrets.editor.name.placeholder", defaultValue: "e.g. ANTHROPIC_API_KEY"),
                            text: binding(\.name)
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled()
                        .frame(maxWidth: .infinity)
                        .disabled(editor.replacing != nil)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .value }
                        .accessibilityIdentifier("CloudSecretsEditor.name")
                    }
                    GridRow {
                        rowLabel(String(localized: "cloudSecrets.editor.value", defaultValue: "Value"))
                        SecureField(
                            CloudSecretsSheetPresentation.valuePlaceholder(model.editorPreset),
                            text: binding(\.value)
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .focused($focus, equals: .value)
                        .onSubmit { save() }
                        .accessibilityLabel(String(localized: "cloudSecrets.editor.value.accessibility", defaultValue: "Secret value"))
                        .accessibilityIdentifier("CloudSecretsEditor.value")
                    }
                    if model.tab == .project, editor.replacing == nil {
                        GridRow {
                            rowLabel(String(localized: "cloudSecrets.editor.project", defaultValue: "Project"))
                            projectField
                        }
                    }
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        scopeLine
                    }
                }

                if let hint = editor.hint {
                    Text(hint)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("CloudSecretsEditor.hint")
                }

                if let error = editor.error {
                    Text(error)
                        .cmuxFont(size: 11)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("CloudSecretsEditor.error")
                }

                HStack(spacing: 8) {
                    if let preset = model.editorPreset, let url = preset.docsURL {
                        Link(CloudSecretsSheetPresentation.credentialLink(preset), destination: url)
                        .cmuxFont(size: 11)
                        .accessibilityIdentifier("CloudSecretsEditor.getKey")
                    }
                    Spacer()
                    if editor.isSaving {
                        ProgressView().controlSize(.small)
                    }
                    Button(String(localized: "cloudSecrets.editor.cancel", defaultValue: "Cancel")) { model.cancelEditor() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("CloudSecretsEditor.cancel")
                    Button(String(localized: "cloudSecrets.editor.save", defaultValue: "Save")) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canSaveEditor)
                        .accessibilityIdentifier("CloudSecretsEditor.save")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.5))
            )
            .onAppear {
                focus = editor.replacing != nil || !editor.name.isEmpty ? .value : .name
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("CloudSecretsEditor")
        }
    }

    private func save() {
        Task { await model.saveEditor() }
    }

    private func title(_ editor: CloudSecretsSheetModel.Editor) -> String {
        if let record = editor.replacing {
            return String(
                format: String(localized: "cloudSecrets.editor.title.replace", defaultValue: "Replace %@"),
                record.name
            )
        }
        return String(localized: "cloudSecrets.editor.title.add", defaultValue: "Add Secret")
    }

    /// Where the secret will apply, as a sentence, plus that the value is
    /// write-only.
    private var scopeLine: some View {
        let scope = model.editorScope
        let text = scope.map {
            String(
                format: String(localized: "cloudSecrets.editor.scope", defaultValue: "Applies to %@. You can replace the value later, but not view it."),
                CloudSecretsSheetPresentation.scopeDescription(
                    $0,
                    machineLabels: model.machineLabels,
                    projectLabels: typedProjectLabels($0)
                )
            )
        } ?? String(localized: "cloudSecrets.editor.scope.needsProject", defaultValue: "Enter the project’s git remote, for example github.com/owner/repo.")
        return Text(text)
            .cmuxFont(size: 11)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The project as typed in the card ("Octocat/Hello-World"), over labels
    /// already known this session.
    private func typedProjectLabels(_ scope: CloudSecretScope) -> [String: String] {
        var labels = model.projectDisplayNames
        if case .project(let key) = scope, let text = model.editor?.projectText,
           let typed = CloudSecretsSheetPresentation.typedProjectLabel(text, key: key) {
            labels[key] = typed
        }
        return labels
    }

    /// A text field for the project key with a menu of known projects.
    private var projectField: some View {
        HStack(spacing: 6) {
            TextField(
                String(localized: "cloudSecrets.editor.project.placeholder", defaultValue: "github.com/owner/repo"),
                text: binding(\.projectText)
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .autocorrectionDisabled()
            .frame(maxWidth: .infinity)
            .focused($focus, equals: .project)
            .accessibilityIdentifier("CloudSecretsEditor.project")
            if !model.projectKeys.isEmpty {
                Menu {
                    ForEach(model.projectKeys, id: \.self) { key in
                        Button(model.projectLabel(key)) { model.editor?.projectText = key }
                            .help(key)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(String(localized: "cloudSecrets.editor.project.choose", defaultValue: "Choose a project"))
            }
        }
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .cmuxFont(size: 11)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .gridColumnAlignment(.trailing)
    }

    /// Edits one editor field; a closed editor ignores writes.
    private func binding(_ keyPath: WritableKeyPath<CloudSecretsSheetModel.Editor, String>) -> Binding<String> {
        Binding(
            get: { model.editor?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var editor = model.editor else { return }
                editor[keyPath: keyPath] = newValue
                editor.error = nil
                model.editor = editor
            }
        )
    }
}
