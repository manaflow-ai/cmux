#if os(iOS)
import CmuxMobileSupport
import CmuxMobileTerminalKit
import SwiftUI

/// Create or edit a user-defined terminal toolbar action.
///
/// A custom action sends literal text when its bar button is tapped — a command
/// like `claude --dangerously-skip-permissions`, a snippet, or any keystrokes.
/// The "Run after typing" toggle appends a Return so the action submits a
/// command instead of only typing it. Saving hands a ``CustomToolbarAction``
/// back to the caller, which persists it through ``TerminalAccessoryConfiguration``.
struct CustomToolbarActionEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let existing: CustomToolbarAction?
    private let onSave: (CustomToolbarAction) -> Void

    @State private var title: String
    @State private var symbolName: String
    @State private var commandText: String
    @State private var runAfterTyping: Bool

    /// Creates the editor.
    /// - Parameters:
    ///   - action: The action to edit, or `nil` to create a new one.
    ///   - onSave: Called with the resulting action when the user taps Save.
    init(action: CustomToolbarAction?, onSave: @escaping (CustomToolbarAction) -> Void) {
        self.existing = action
        self.onSave = onSave
        let seed = Self.seed(from: action)
        _title = State(initialValue: seed.title)
        _symbolName = State(initialValue: seed.symbolName)
        _commandText = State(initialValue: seed.text)
        _runAfterTyping = State(initialValue: seed.runAfterTyping)
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
                    TextField(
                        L10n.string("mobile.toolbar.editor.iconPlaceholder", defaultValue: "SF Symbol name"),
                        text: $symbolName
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("CustomActionIconField")
                } header: {
                    Text(L10n.string("mobile.toolbar.editor.iconHeader", defaultValue: "Icon"))
                } footer: {
                    Text(L10n.string(
                        "mobile.toolbar.editor.iconFooter",
                        defaultValue: "Optional SF Symbol shown instead of the label. The label remains the accessibility name."
                    ))
                }

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

    private var navigationTitle: String {
        existing == nil
            ? L10n.string("mobile.toolbar.editor.addTitle", defaultValue: "Add Action")
            : L10n.string("mobile.toolbar.editor.editTitle", defaultValue: "Edit Action")
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSymbolName: String {
        symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedTitle.isEmpty && !commandText.isEmpty
    }

    private func save() {
        guard isValid else { return }
        let text = runAfterTyping ? commandText + "\n" : commandText
        let icon = trimmedSymbolName.isEmpty ? nil : trimmedSymbolName
        let action = CustomToolbarAction(
            id: existing?.id ?? UUID(),
            title: trimmedTitle,
            symbolName: icon,
            payload: .text(text)
        )
        onSave(action)
        dismiss()
    }

    private static func seed(
        from action: CustomToolbarAction?
    ) -> (title: String, symbolName: String, text: String, runAfterTyping: Bool) {
        guard let action, case let .text(stored) = action.payload else {
            return (action?.title ?? "", action?.symbolName ?? "", "", true)
        }
        if stored.hasSuffix("\n") {
            return (action.title, action.symbolName ?? "", String(stored.dropLast()), true)
        }
        return (action.title, action.symbolName ?? "", stored, false)
    }
}
#endif
