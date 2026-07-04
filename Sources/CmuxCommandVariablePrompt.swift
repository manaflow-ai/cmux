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
struct CmuxCommandVariablePrompt {
    /// The variables to prompt for, in display order.
    let variables: [CmuxCommandVariable]
    /// Optional dialog title (typically the command's display name).
    let displayTitle: String?

    /// Presents the variable prompt and invokes `completion` with the collected
    /// `[name: value]` map when the user confirms. Cancelling does nothing.
    ///
    /// - Returns: `true` once the prompt has been presented (always, given a
    ///   non-empty `variables`). When `variables` is empty the completion runs
    ///   immediately with an empty map.
    @discardableResult
    func present(
        in presentingWindow: NSWindow?,
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

        let fields = makeFields()
        alert.accessoryView = makeAccessoryView(fields: fields)
        alert.layout()
        if let firstField = fields.first {
            alert.window.initialFirstResponder = firstField
        }

        let captured = variables
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            var values: [String: String] = [:]
            for (variable, field) in zip(captured, fields) {
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

    private func makeFields() -> [NSTextField] {
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

    private func makeAccessoryView(fields: [NSTextField]) -> NSView {
        let rowHeight = Self.labelHeight + Self.labelToInputGap + Self.inputHeight
        let totalHeight = CGFloat(variables.count) * rowHeight
            + CGFloat(max(0, variables.count - 1)) * Self.rowGap
        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: Self.fieldWidth, height: totalHeight)
        )

        // Lay the rows out top-to-bottom in AppKit's default bottom-left origin
        // coordinate space (no flipped-view subclass needed).
        for (offset, pair) in zip(variables, fields).enumerated() {
            let (variable, field) = pair
            let rowTop = totalHeight - CGFloat(offset) * (rowHeight + Self.rowGap)
            let rowBottom = rowTop - rowHeight

            let label = NSTextField(labelWithString: variable.name)
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(
                x: 0,
                y: rowBottom + Self.inputHeight + Self.labelToInputGap,
                width: Self.fieldWidth,
                height: Self.labelHeight
            )
            container.addSubview(label)

            field.frame = NSRect(x: 0, y: rowBottom, width: Self.fieldWidth, height: Self.inputHeight)
            container.addSubview(field)
        }

        // Tab order: walk the fields top-to-bottom, then loop back to the first.
        for index in fields.indices {
            fields[index].nextKeyView = fields[(index + 1) % fields.count]
        }

        return container
    }
}
