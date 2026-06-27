#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminalKit
import SwiftUI

/// Create or edit a user-defined terminal toolbar action.
///
/// A custom action can send literal text, one modified terminal key, or a
/// multi-step macro. Saving hands a ``CustomToolbarAction`` back to the caller,
/// which persists it through ``TerminalAccessoryConfiguration``.
struct CustomToolbarActionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let existing: CustomToolbarAction?
    private let onSave: (CustomToolbarAction) -> Void

    @State private var title: String
    @State private var mode: ToolbarActionEditorMode
    @State private var commandText: String
    @State private var runAfterTyping: Bool
    @State private var keyModifiers: TerminalKeyModifier
    @State private var selectedKey: TerminalSpecialKey
    @State private var macroSteps: [ToolbarMacroStepDraft]

    /// Creates the editor.
    /// - Parameters:
    ///   - action: The action to edit, or `nil` to create a new one.
    ///   - onSave: Called with the resulting action when the user taps Save.
    init(action: CustomToolbarAction?, onSave: @escaping (CustomToolbarAction) -> Void) {
        self.existing = action
        self.onSave = onSave
        let seed = Self.seed(from: action)
        _title = State(initialValue: seed.title)
        _mode = State(initialValue: seed.mode)
        _commandText = State(initialValue: seed.text)
        _runAfterTyping = State(initialValue: seed.runAfterTyping)
        _keyModifiers = State(initialValue: seed.keyModifiers)
        _selectedKey = State(initialValue: seed.selectedKey)
        _macroSteps = State(initialValue: seed.macroSteps)
    }

    var body: some View {
        NavigationStack {
            Form {
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

                Section {
                    Picker(
                        L10n.string("mobile.toolbar.editor.typeHeader", defaultValue: "Action Type"),
                        selection: $mode
                    ) {
                        ForEach(ToolbarActionEditorMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text(L10n.string("mobile.toolbar.editor.typeHeader", defaultValue: "Action Type"))
                }

                switch mode {
                case .text:
                    textSection
                case .keyCombo:
                    keyComboSection
                case .macro:
                    macroSection
                }
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
                    .disabled(!isValid)
                    .accessibilityIdentifier("CustomActionSaveButton")
                }
            }
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

    private var keyComboSection: some View {
        Section {
            ToolbarKeyComboFields(modifiers: $keyModifiers, key: $selectedKey)
                .accessibilityIdentifier("CustomActionKeyComboFields")

            if keyComboPayload == nil {
                Text(L10n.string(
                    "mobile.toolbar.editor.unsupportedCombo",
                    defaultValue: "This key combo is not supported yet."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.string("mobile.toolbar.editor.keyComboHeader", defaultValue: "Key Combo"))
        } footer: {
            Text(L10n.string(
                "mobile.toolbar.editor.keyComboFooter",
                defaultValue: "Sends one modified terminal key, such as Shift-Tab or Option-Left."
            ))
        }
    }

    @ViewBuilder private var macroSection: some View {
        ForEach(macroSteps) { step in
            macroStepSection(for: step)
        }

        Section {
            Button {
                macroSteps.append(.textStep())
            } label: {
                Label(
                    L10n.string("mobile.toolbar.editor.addTextStep", defaultValue: "Add Text Step"),
                    systemImage: "text.cursor"
                )
            }
            .accessibilityIdentifier("CustomActionAddTextStepButton")

            Button {
                macroSteps.append(.keyComboStep())
            } label: {
                Label(
                    L10n.string("mobile.toolbar.editor.addKeyStep", defaultValue: "Add Key Step"),
                    systemImage: "keyboard"
                )
            }
            .accessibilityIdentifier("CustomActionAddKeyStepButton")
        } header: {
            Text(L10n.string("mobile.toolbar.editor.addStepHeader", defaultValue: "Add Step"))
        } footer: {
            Text(L10n.string(
                "mobile.toolbar.editor.macroFooter",
                defaultValue: "Runs each step in order. Text steps type exactly what you enter; key steps send one key combo."
            ))
        }
    }

    @ViewBuilder private func macroStepSection(for step: ToolbarMacroStepDraft) -> some View {
        if let index = macroSteps.firstIndex(where: { $0.id == step.id }) {
            Section {
                ToolbarMacroStepEditor(step: $macroSteps[index])

                Button(role: .destructive) {
                    macroSteps.removeAll { $0.id == step.id }
                } label: {
                    Label(
                        L10n.string("mobile.toolbar.editor.deleteStep", defaultValue: "Delete Step"),
                        systemImage: "trash"
                    )
                }
                .accessibilityIdentifier("CustomActionDeleteStepButton-\(index + 1)")
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    if index == macroSteps.startIndex {
                        Text(L10n.string("mobile.toolbar.editor.macroHeader", defaultValue: "Macro Steps"))
                    }
                    Text(macroStepTitle(index: index + 1))
                }
            }
        }
    }

    private var keyComboPayload: ToolbarActionPayload? {
        let payload = ToolbarActionPayload.keyCombo(modifiers: keyModifiers, key: selectedKey)
        guard payload.output != nil else { return nil }
        return payload
    }

    private var macroPayload: ToolbarActionPayload? {
        let steps = macroSteps.compactMap(\.macroStep)
        guard steps.count == macroSteps.count else { return nil }
        let payload = ToolbarActionPayload.macro(steps)
        guard payload.output != nil else { return nil }
        return payload
    }

    private var payload: ToolbarActionPayload? {
        switch mode {
        case .text:
            guard !commandText.isEmpty else { return nil }
            return .text(runAfterTyping ? commandText + "\n" : commandText)
        case .keyCombo:
            return keyComboPayload
        case .macro:
            return macroPayload
        }
    }

    private var navigationTitle: String {
        existing == nil
            ? L10n.string("mobile.toolbar.editor.addTitle", defaultValue: "Add Action")
            : L10n.string("mobile.toolbar.editor.editTitle", defaultValue: "Edit Action")
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedTitle.isEmpty && payload != nil
    }

    private func macroStepTitle(index: Int) -> String {
        let format = L10n.string("mobile.toolbar.editor.stepHeaderFormat", defaultValue: "Step %d")
        return String(format: format, index)
    }

    private func save() {
        guard let payload, isValid else { return }
        let action = CustomToolbarAction(
            id: existing?.id ?? UUID(),
            title: trimmedTitle,
            symbolName: nil,
            payload: payload
        )
        onSave(action)
        dismiss()
    }

    private static func seed(
        from action: CustomToolbarAction?
    ) -> (
        mode: ToolbarActionEditorMode,
        title: String,
        text: String,
        runAfterTyping: Bool,
        keyModifiers: TerminalKeyModifier,
        selectedKey: TerminalSpecialKey,
        macroSteps: [ToolbarMacroStepDraft]
    ) {
        guard let action else {
            return (
                .text,
                "",
                "",
                true,
                [.shift],
                .tab,
                [.keyComboStep()]
            )
        }

        switch action.payload {
        case let .text(stored):
            let seed = ToolbarMacroStepDraft.textSeed(from: stored)
            return (
                .text,
                action.title,
                seed.text,
                seed.runAfterTyping,
                [.shift],
                .tab,
                [.keyComboStep()]
            )
        case let .keyCombo(modifiers, key):
            return (
                .keyCombo,
                action.title,
                "",
                true,
                modifiers,
                key,
                [.keyComboStep()]
            )
        case let .macro(steps):
            let drafts = steps.map(ToolbarMacroStepDraft.init(step:))
            return (
                .macro,
                action.title,
                "",
                true,
                [.shift],
                .tab,
                drafts.isEmpty ? [.keyComboStep()] : drafts
            )
        }
    }
}
#endif
