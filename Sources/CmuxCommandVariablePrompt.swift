import AppKit
import Foundation

/// Presents an inline prompt asking the user to fill in the `{{variable}}`
/// placeholders of a custom command before it runs.
///
/// The prompt is an `NSAlert` with an accessory view of labeled text fields —
/// one per variable — matching the look of the existing project-action confirm
/// dialog in ``CmuxConfigExecutor``. Because every command entrypoint (Command
/// Palette, surface tab-bar buttons, dock, …) funnels shell commands through
/// ``CmuxConfigExecutor/prepareShellInputIfAuthorized(_:confirm:actionID:target:configSourcePath:globalConfigPath:displayTitle:icon:iconSourcePath:presentingWindow:onAuthorized:)``,
/// wiring the prompt there gives variable support to all of them at once.
@MainActor
enum CmuxCommandVariablePrompt {
    /// Presents the variable prompt and invokes `completion` with the collected
    /// `[name: value]` map when the user confirms. Cancelling does nothing.
    ///
    /// - Returns: `true` once the prompt has been presented (always, given a
    ///   non-empty `variables`). When `variables` is empty the completion runs
    ///   immediately with an empty map.
    @discardableResult
    static func present(
        variables: [CmuxCommandVariable],
        displayTitle: String?,
        presentingWindow: NSWindow?,
        completion: @escaping ([String: String]) -> Void
    ) -> Bool {
        guard !variables.isEmpty else {
            completion([:])
            return true
        }

        let alert = NSAlert()
        let trimmedTitle = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.messageText = (trimmedTitle?.isEmpty == false)
            ? trimmedTitle!
            : String(
                localized: "dialog.cmuxConfig.commandVariables.title",
                defaultValue: "Enter Command Variables"
            )
        alert.informativeText = String(
            localized: "dialog.cmuxConfig.commandVariables.message",
            defaultValue: "Fill in the values for this command before running."
        )
        alert.addButton(withTitle: String(
            localized: "dialog.cmuxConfig.commandVariables.run",
            defaultValue: "Run"
        ))
        alert.addButton(withTitle: String(
            localized: "common.cancel",
            defaultValue: "Cancel"
        ))

        let fields = makeFields(for: variables)
        alert.accessoryView = makeAccessoryView(variables: variables, fields: fields)
        alert.layout()
        if let firstField = fields.first {
            alert.window.initialFirstResponder = firstField
        }

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            var values: [String: String] = [:]
            for (variable, field) in zip(variables, fields) {
                values[variable.name] = field.stringValue
            }
            completion(values)
        }

        if let presentingWindow {
            alert.beginSheetModal(for: presentingWindow, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
        return true
    }

    // MARK: - Accessory layout

    private static let fieldWidth: CGFloat = 320
    private static let labelHeight: CGFloat = 15
    private static let inputHeight: CGFloat = 22
    private static let labelToInputGap: CGFloat = 3
    private static let rowGap: CGFloat = 10

    private static func makeFields(for variables: [CmuxCommandVariable]) -> [NSTextField] {
        variables.map { variable in
            let field = NSTextField(string: variable.defaultValue ?? "")
            field.placeholderString = variable.name
            field.translatesAutoresizingMaskIntoConstraints = true
            field.lineBreakMode = .byTruncatingTail
            field.isEditable = true
            field.isSelectable = true
            return field
        }
    }

    private static func makeAccessoryView(
        variables: [CmuxCommandVariable],
        fields: [NSTextField]
    ) -> NSView {
        let rowHeight = labelHeight + labelToInputGap + inputHeight
        let totalHeight = CGFloat(variables.count) * rowHeight
            + CGFloat(max(0, variables.count - 1)) * rowGap
        let container = FlippedView(
            frame: NSRect(x: 0, y: 0, width: fieldWidth, height: totalHeight)
        )

        var y: CGFloat = 0
        for (variable, field) in zip(variables, fields) {
            let label = NSTextField(labelWithString: variable.name)
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 0, y: y, width: fieldWidth, height: labelHeight)
            container.addSubview(label)

            field.frame = NSRect(
                x: 0,
                y: y + labelHeight + labelToInputGap,
                width: fieldWidth,
                height: inputHeight
            )
            container.addSubview(field)

            y += rowHeight + rowGap
        }

        // Tab order: walk the fields top-to-bottom, then loop back to the first.
        for index in fields.indices {
            fields[index].nextKeyView = fields[(index + 1) % fields.count]
        }

        return container
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}
