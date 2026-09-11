#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminalKit
import SwiftUI

/// Create or edit a user-defined terminal toolbar action.
///
/// An action is one of two kinds, chosen with the type picker:
/// - **Text** sends a literal command or snippet when tapped — e.g.
///   `claude --dangerously-skip-permissions`. "Run after typing" appends a Return
///   so it submits the command instead of only typing it.
/// - **Key Sequence** sends an ordered macro of modified special keys and/or text
///   snippets — e.g. a single `⇧ Tab` to rotate an agent's permission mode, or a
///   short multi-step sequence.
///
/// The pure seed/build/validity logic lives in ``CustomToolbarActionDraft``;
/// this view holds `@State` mirrors of its fields and projects them back into a
/// draft to drive Save. Saving hands a ``CustomToolbarAction`` to the caller,
/// which persists it through ``TerminalAccessoryConfiguration``.
struct CustomToolbarActionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let existing: CustomToolbarAction?
    private let onSave: (CustomToolbarAction) -> Void

    @State private var title: String
    @State private var mode: CustomToolbarActionDraftMode
    @State private var commandText: String
    @State private var runAfterTyping: Bool
    @State private var steps: [EditableMacroStep]
    // Owned (not the ambient EditButton state) so it can be force-reset when the
    // step list empties — otherwise deleting down to the last step hides the
    // reorder control while edit mode stays active, trapping the user.
    @State private var stepsEditMode: EditMode = .inactive

    /// Creates the editor.
    /// - Parameters:
    ///   - action: The action to edit, or `nil` to create a new one.
    ///   - onSave: Called with the resulting action when the user taps Save.
    init(action: CustomToolbarAction?, onSave: @escaping (CustomToolbarAction) -> Void) {
        self.existing = action
        self.onSave = onSave
        let seed = CustomToolbarActionDraft(action: action)
        _title = State(initialValue: seed.title)
        _mode = State(initialValue: seed.mode)
        _commandText = State(initialValue: seed.commandText)
        _runAfterTyping = State(initialValue: seed.runAfterTyping)
        _steps = State(initialValue: seed.steps.map { EditableMacroStep($0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                titleSection
                typeSection
                if mode == .text {
                    textSection
                } else {
                    keySequenceSection
                }
            }
            .environment(\.editMode, $stepsEditMode)
            .onChange(of: steps.isEmpty) { _, isEmpty in
                // Never leave the list in edit mode with nothing to edit.
                if isEmpty { stepsEditMode = .inactive }
            }
            .onChange(of: mode) { _, newMode in
                // Leaving the key-sequence editor should drop edit mode too.
                if newMode != .keySequence { stepsEditMode = .inactive }
            }
            .navigationTitle(navigationTitle)
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("CustomActionCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.save", defaultValue: "Save")) {
                        save()
                    }
                    .disabled(!draft.isValid)
                    .accessibilityIdentifier("CustomActionSaveButton")
                }
            }
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        Section {
            TextField(
                L10n.string("mobile.toolbar.editor.titlePlaceholder", defaultValue: "Button label"),
                text: $title
            )
            .autocorrectionDisabled()
            .accessibilityIdentifier("CustomActionTitleField")
        } header: {
            Text(L10n.string("mobile.toolbar.editor.titleHeader", defaultValue: "Label"))
        } footer: {
            Text(L10n.string(
                "mobile.toolbar.editor.titleFooter",
                defaultValue: "Shown on the button in the keyboard toolbar."
            ))
        }
    }

    private var typeSection: some View {
        Section {
            Picker(
                L10n.string("mobile.toolbar.editor.typeHeader", defaultValue: "Type"),
                selection: $mode
            ) {
                Text(L10n.string("mobile.toolbar.editor.type.text", defaultValue: "Text"))
                    .tag(CustomToolbarActionDraftMode.text)
                Text(L10n.string("mobile.toolbar.editor.type.keySequence", defaultValue: "Key Sequence"))
                    .tag(CustomToolbarActionDraftMode.keySequence)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("CustomActionModePicker")
        }
    }

    private var textSection: some View {
        Section {
            TextField(
                L10n.string("mobile.toolbar.editor.commandPlaceholder", defaultValue: "claude --dangerously-skip-permissions"),
                text: $commandText,
                axis: .vertical
            )
            .lineLimit(1...6)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(.body, design: .monospaced))
            .accessibilityIdentifier("CustomActionCommandField")

            Toggle(isOn: $runAfterTyping) {
                Text(L10n.string("mobile.toolbar.editor.runAfterTyping", defaultValue: "Run after typing"))
            }
            .accessibilityIdentifier("CustomActionRunToggle")
        } header: {
            Text(L10n.string("mobile.toolbar.editor.commandHeader", defaultValue: "Sends"))
        } footer: {
            Text(L10n.string(
                "mobile.toolbar.editor.commandFooter",
                defaultValue: "The text typed into the terminal when tapped. Turn on Run after typing to press Return automatically."
            ))
        }
    }

    private var keySequenceSection: some View {
        Section {
            ForEach($steps) { $step in
                stepRow($step)
            }
            .onMove { steps.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { steps.remove(atOffsets: $0) }

            Menu {
                Button {
                    steps.append(EditableMacroStep(.keyCombo(modifiers: [], key: .tab)))
                } label: {
                    Label(
                        L10n.string("mobile.toolbar.editor.addKeyStep", defaultValue: "Add Key Combo"),
                        systemImage: "command"
                    )
                }
                Button {
                    steps.append(EditableMacroStep(.text("")))
                } label: {
                    Label(
                        L10n.string("mobile.toolbar.editor.addTextStep", defaultValue: "Add Text"),
                        systemImage: "text.cursor"
                    )
                }
            } label: {
                Label(
                    L10n.string("mobile.toolbar.editor.addStep", defaultValue: "Add Step"),
                    systemImage: "plus"
                )
            }
            .disabled(!canAddMacroStep)
            .accessibilityIdentifier("CustomActionAddStepButton")
        } header: {
            HStack {
                Text(L10n.string("mobile.toolbar.editor.stepsHeader", defaultValue: "Sends in Order"))
                Spacer()
                if !steps.isEmpty {
                    EditButton()
                        .accessibilityIdentifier("CustomActionStepsEditButton")
                }
            }
        } footer: {
            Text(L10n.string(
                "mobile.toolbar.editor.stepsFooter",
                defaultValue: "Each step is sent in order when the button is tapped. Add a key combo (e.g. ⇧ Tab to rotate an agent's permission mode) or a text snippet."
            ))
        }
    }

    // MARK: - Step rows

    @ViewBuilder
    private func stepRow(_ step: Binding<EditableMacroStep>) -> some View {
        switch step.wrappedValue.step {
        case .keyCombo:
            keyComboStepRow(step)
        case .text:
            textStepRow(step)
        }
    }

    @ViewBuilder
    private func keyComboStepRow(_ step: Binding<EditableMacroStep>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(TerminalKeyModifier.editorModifierOptions) { option in
                    Toggle(option.glyph, isOn: modifierBinding(step, option.modifier))
                        .toggleStyle(.button)
                        .accessibilityLabel(option.name)
                }
                Spacer(minLength: 8)
                Picker(
                    L10n.string("mobile.toolbar.editor.keyPickerLabel", defaultValue: "Key"),
                    selection: keyBinding(step)
                ) {
                    ForEach(TerminalSpecialKey.editorPickerOrder, id: \.self) { key in
                        Text(key.editorDisplayName).tag(key)
                    }
                }
                .labelsHidden()
            }

            if step.wrappedValue.step.output == nil {
                Text(L10n.string(
                    "mobile.toolbar.editor.unsupportedCombo",
                    defaultValue: "This combination isn't supported and won't send anything."
                ))
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func textStepRow(_ step: Binding<EditableMacroStep>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                L10n.string("mobile.toolbar.editor.textStepPlaceholder", defaultValue: "Text to send"),
                text: textBinding(step)
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(.body, design: .monospaced))

            // Mirror the key-combo row's inline cue: an empty text step sends
            // nothing and keeps Save disabled, so say so instead of leaving the
            // greyed-out Save unexplained.
            if step.wrappedValue.step.output == nil {
                Text(L10n.string(
                    "mobile.toolbar.editor.emptyTextStep",
                    defaultValue: "Add text, or this step won't send anything."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings into a step's associated values

    private func modifierBinding(
        _ step: Binding<EditableMacroStep>,
        _ modifier: TerminalKeyModifier
    ) -> Binding<Bool> {
        Binding(
            get: {
                if case let .keyCombo(modifiers, _) = step.wrappedValue.step {
                    return modifiers.contains(modifier)
                }
                return false
            },
            set: { isOn in
                guard case let .keyCombo(modifiers, key) = step.wrappedValue.step else { return }
                var updated = modifiers
                if isOn { updated.insert(modifier) } else { updated.remove(modifier) }
                step.wrappedValue.step = .keyCombo(modifiers: updated, key: key)
            }
        )
    }

    private func keyBinding(_ step: Binding<EditableMacroStep>) -> Binding<TerminalSpecialKey> {
        Binding(
            get: {
                if case let .keyCombo(_, key) = step.wrappedValue.step { return key }
                return .tab
            },
            set: { newKey in
                guard case let .keyCombo(modifiers, _) = step.wrappedValue.step else { return }
                step.wrappedValue.step = .keyCombo(modifiers: modifiers, key: newKey)
            }
        )
    }

    private func textBinding(_ step: Binding<EditableMacroStep>) -> Binding<String> {
        Binding(
            get: {
                if case let .text(value) = step.wrappedValue.step { return value }
                return ""
            },
            set: { newValue in step.wrappedValue.step = .text(newValue) }
        )
    }

    // MARK: - Save

    private var navigationTitle: String {
        existing == nil
            ? L10n.string("mobile.toolbar.editor.addTitle", defaultValue: "Add Action")
            : L10n.string("mobile.toolbar.editor.editTitle", defaultValue: "Edit Action")
    }

    private var canAddMacroStep: Bool {
        steps.count < CustomToolbarActionDraft.maximumKeySequenceStepCount
    }

    /// Live projection of the editor's `@State` into the pure draft model.
    private var draft: CustomToolbarActionDraft {
        CustomToolbarActionDraft(
            title: title,
            mode: mode,
            commandText: commandText,
            runAfterTyping: runAfterTyping,
            steps: steps.map(\.step)
        )
    }

    private func save() {
        guard let action = draft.build(id: existing?.id ?? UUID()) else { return }
        onSave(action)
        dismiss()
    }
}
#endif
