import AppKit
import CmuxFoundation
import Foundation

/// Edits the values persisted for an inline workspace layout's template parameters.
@MainActor
struct WorkspaceActionParameterEditor {
    private let processEnvironment: [String: String]

    init(processEnvironment: [String: String]) {
        self.processEnvironment = processEnvironment
    }

    /// Presents the explicit edit flow and returns false when the layout has no parameters.
    @discardableResult
    func present(
        definition: CmuxWorkspaceDefinition,
        displayName: String,
        presentingWindow: NSWindow,
        completion: @escaping ([String: String]?) -> Void
    ) -> Bool {
        let inputs = definition.templateParameterInputs(
            processEnvironment: processEnvironment
        )
        guard !inputs.isEmpty else { return false }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "dialog.workspaceLayoutParameters.edit.title",
            defaultValue: "Edit Layout Parameters"
        )
        let messageFormat = String(
            localized: "dialog.workspaceLayoutParameters.edit.message",
            defaultValue: "Changes are saved to “%@” and used automatically each time you open this layout."
        )
        alert.informativeText = String.localizedStringWithFormat(
            messageFormat,
            displayName
        )
        alert.addButton(withTitle: String(
            localized: "dialog.workspaceLayoutParameters.edit.confirm",
            defaultValue: "Save Changes"
        ))
        alert.addButton(withTitle: String(
            localized: "common.cancel",
            defaultValue: "Cancel"
        ))

        let fields = makeFields(inputs)
        alert.accessoryView = makeAccessoryView(inputs: inputs, fields: fields)
        let initialInput = inputs.first(where: { $0.suggestedValue == nil }) ?? inputs[0]
        alert.window.initialFirstResponder = fields[initialInput.name]

        alert.beginSheetModal(for: presentingWindow) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(Dictionary(uniqueKeysWithValues: inputs.compactMap { input in
                fields[input.name].map { (input.name, $0.stringValue) }
            }))
        }
        return true
    }

    private func makeFields(
        _ inputs: [CmuxTemplateParameterInput]
    ) -> [String: NSTextField] {
        Dictionary(uniqueKeysWithValues: inputs.map { input in
            let field = NSTextField(string: input.suggestedValue ?? "")
            field.placeholderString = input.suggestedValue == nil
                ? String(
                    localized: "dialog.workspaceLayoutParameters.edit.placeholder",
                    defaultValue: "Enter a value"
                )
                : nil
            field.identifier = NSUserInterfaceItemIdentifier(
                "workspaceLayoutParameters.value.\(input.name)"
            )
            field.setAccessibilityLabel(input.name)
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            return (input.name, field)
        })
    }

    private func makeAccessoryView(
        inputs: [CmuxTemplateParameterInput],
        fields: [String: NSTextField]
    ) -> NSView {
        let rows: [[NSView]] = inputs.compactMap { input in
            guard let field = fields[input.name] else { return nil }
            let label = NSTextField(labelWithString: input.name)
            label.alignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)
            return [label, field]
        }
        let grid = NSGridView(views: rows)
        grid.columnSpacing = 12
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.setContentHuggingPriority(.required, for: .vertical)
        grid.layoutSubtreeIfNeeded()
        grid.setFrameSize(grid.fittingSize)
        return grid
    }
}
