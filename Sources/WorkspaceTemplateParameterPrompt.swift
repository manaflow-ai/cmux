import AppKit
import CmuxFoundation
import Foundation

/// Shared parameter collection for every interactive workspace-template launch.
@MainActor
struct WorkspaceTemplateParameterPrompt {
    private let processEnvironment: [String: String]

    init(processEnvironment: [String: String]) {
        self.processEnvironment = processEnvironment
    }

    /// Requests editable values when a definition explicitly enables templates.
    /// The completion receives `nil` when the user cancels.
    @discardableResult
    func requestParameters(
        for definition: CmuxWorkspaceDefinition,
        displayName: String,
        presentingWindow: NSWindow?,
        completion: @escaping ([String: String]?) -> Void
    ) -> Bool {
        let inputs = definition.templateParameterInputs(
            processEnvironment: processEnvironment
        )
        guard !inputs.isEmpty else {
            completion([:])
            return true
        }

        let alert = NSAlert()
        alert.messageText = String(
            localized: "dialog.workspaceTemplate.configure.title",
            defaultValue: "Configure Workspace Parameters"
        )
        let messageFormat = String(
            localized: "dialog.workspaceTemplate.configure.message",
            defaultValue: "Set values for “%@” before creating the workspace."
        )
        alert.informativeText = String.localizedStringWithFormat(
            messageFormat,
            displayName
        )
        alert.addButton(withTitle: String(
            localized: "dialog.workspaceTemplate.configure.confirm",
            defaultValue: "Create Workspace"
        ))
        alert.addButton(withTitle: String(
            localized: "common.cancel",
            defaultValue: "Cancel"
        ))

        let fields = makeFields(inputs)
        alert.accessoryView = makeAccessoryView(inputs: inputs, fields: fields)
        alert.window.initialFirstResponder = inputs.firstIndex(where: {
            $0.suggestedValue == nil
        }).flatMap { fields[inputs[$0].name] } ?? fields[inputs[0].name]

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(Dictionary(uniqueKeysWithValues: inputs.compactMap { input in
                fields[input.name].map { (input.name, $0.stringValue) }
            }))
        }

        if let window = presentingWindow ?? NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(runCmuxModalAlert(alert))
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
                    localized: "dialog.workspaceTemplate.configure.placeholder",
                    defaultValue: "Enter a value"
                )
                : nil
            field.identifier = NSUserInterfaceItemIdentifier(
                "workspaceTemplate.parameter.\(input.name)"
            )
            field.setAccessibilityLabel(input.name)
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
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
