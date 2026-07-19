import AppKit
import Foundation

@MainActor
final class CmuxRunURLConfirmationPresenter {
    private let nonModalFailurePresenter: CmuxRunURLNonModalFailurePresenter

    init(
        nonModalFailurePresenter: CmuxRunURLNonModalFailurePresenter? = nil
    ) {
        self.nonModalFailurePresenter = nonModalFailurePresenter
            ?? CmuxRunURLNonModalFailurePresenter()
    }

    func confirm(_ plan: CmuxRunExecutionPlan, presentingWindow: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "dialog.runURL.title",
            defaultValue: "Run a Command From an External Link?"
        )
        alert.informativeText = String(
            localized: "dialog.runURL.message",
            defaultValue: "cmux cannot verify which website or app opened this link. The command will run with your user account's permissions. Review every field before continuing."
        )
        alert.addButton(
            withTitle: String(localized: "dialog.runURL.cancel", defaultValue: "Cancel")
        )
        alert.addButton(
            withTitle: String(localized: "dialog.runURL.run", defaultValue: "Run Command")
        )
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[1].isEnabled = false

        let gate = CmuxRunURLConfirmationGate(runButton: alert.buttons[1])
        alert.accessoryView = accessoryView(for: plan, gate: gate)
        let response = withExtendedLifetime(gate) {
            alert.runCmuxModal(presentingWindow: presentingWindow)
        }
        cmuxDebugLog("runURL.confirm response=\(response.rawValue)")
        return response == .alertSecondButtonReturn
    }

    func showParseFailure(_ error: CmuxRunURLParseError, presentingWindow: NSWindow? = nil) {
        showFailureMessage(parseFailureMessage(error), presentingWindow: presentingWindow)
    }

    func showFailure(_ error: CmuxRunURLExecutionError, presentingWindow: NSWindow? = nil) {
        showFailureMessage(executionFailureMessage(error), presentingWindow: presentingWindow)
    }

    func showNonModalParseFailure(_ error: CmuxRunURLParseError) {
        showNonModalFailureMessage(parseFailureMessage(error))
    }

    func showNonModalFailure(_ error: CmuxRunURLExecutionError) {
        showNonModalFailureMessage(executionFailureMessage(error))
    }

    private func accessoryView(
        for plan: CmuxRunExecutionPlan,
        gate: CmuxRunURLConfirmationGate
    ) -> NSView {
        let contentWidth: CGFloat = 560
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(detailRow(
            label: String(localized: "dialog.runURL.field.placement", defaultValue: "Placement"),
            value: plan.placementDescription
        ))
        stack.addArrangedSubview(targetDetailRow(value: plan.targetDescription))
        stack.addArrangedSubview(directoryDetailRow(value: plan.workingDirectory))

        let commandLabel = NSTextField(labelWithString: String(
            localized: "dialog.runURL.field.command",
            defaultValue: "Command"
        ))
        commandLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(commandLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityIdentifier("cmux.runURL.command")
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 150))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = NSSize(width: 0, height: 150)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.string = plan.command
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scrollView.documentView = textView
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: contentWidth),
            scrollView.heightAnchor.constraint(equalToConstant: 150)
        ])
        stack.addArrangedSubview(scrollView)

        let checkbox = NSButton(
            checkboxWithTitle: String(
                localized: "dialog.runURL.reviewed",
                defaultValue: "I reviewed this command, directory, and target and trust this request."
            ),
            target: gate,
            action: #selector(CmuxRunURLConfirmationGate.reviewStateChanged(_:))
        )
        checkbox.lineBreakMode = .byWordWrapping
        checkbox.setAccessibilityIdentifier("cmux.runURL.reviewed")
        gate.checkbox = checkbox
        stack.addArrangedSubview(checkbox)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 350))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            checkbox.widthAnchor.constraint(equalTo: container.widthAnchor)
        ])
        return container
    }

    private func detailRow(label: String, value: String, monospaced: Bool = false) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8

        let labelField = NSTextField(labelWithString: "\(label):")
        labelField.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        let valueField = NSTextField(wrappingLabelWithString: value)
        valueField.font = monospaced
            ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        valueField.maximumNumberOfLines = 3
        valueField.lineBreakMode = .byTruncatingMiddle
        valueField.setAccessibilityValue(value)
        row.addArrangedSubview(labelField)
        row.addArrangedSubview(valueField)
        row.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return row
    }

    func directoryDetailRow(value: String) -> NSView {
        scrollingDetailRow(
            label: String(localized: "dialog.runURL.field.directory", defaultValue: "Directory"),
            value: value,
            accessibilityIdentifier: "cmux.runURL.directory"
        )
    }

    func targetDetailRow(value: String) -> NSView {
        scrollingDetailRow(
            label: String(localized: "dialog.runURL.field.target", defaultValue: "Target"),
            value: value,
            accessibilityIdentifier: "cmux.runURL.target"
        )
    }

    private func scrollingDetailRow(
        label: String,
        value: String,
        accessibilityIdentifier: String
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8

        let labelField = NSTextField(labelWithString: "\(label):")
        labelField.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        labelField.setContentHuggingPriority(.required, for: .horizontal)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setAccessibilityIdentifier(accessibilityIdentifier)
        scrollView.setAccessibilityValue(value)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let font = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        let measuredWidth = (value as NSString).size(withAttributes: [.font: font]).width
        let textView = NSTextView(frame: NSRect(
            x: 0,
            y: 0,
            width: max(440, ceil(measuredWidth) + 12),
            height: 24
        ))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.minSize = NSSize(width: 0, height: 24)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 24)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: 24
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = true
        textView.font = font
        textView.string = value
        textView.textContainerInset = NSSize(width: 6, height: 4)
        textView.setAccessibilityValue(value)
        scrollView.documentView = textView

        row.addArrangedSubview(labelField)
        row.addArrangedSubview(scrollView)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: 560),
            scrollView.heightAnchor.constraint(equalToConstant: 42)
        ])
        return row
    }

    private func showFailureMessage(_ message: String, presentingWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.runURL.failure.title",
            defaultValue: "Command Link Blocked"
        )
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "dialog.runURL.failure.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal(presentingWindow: presentingWindow)
    }

    private func showNonModalFailureMessage(_ message: String) {
        nonModalFailurePresenter.show(message: message)
    }

    private func parseFailureMessage(_ error: CmuxRunURLParseError) -> String {
        switch error {
        case .unsupportedURLShape:
            return String(localized: "dialog.runURL.error.shape", defaultValue: "The command link has an unsupported URL shape.")
        case .missingParameter(let parameter):
            return String.localizedStringWithFormat(
                String(localized: "dialog.runURL.error.missing", defaultValue: "The command link is missing the required %@ parameter."),
                parameter
            )
        case .emptyParameter(let parameter):
            return String.localizedStringWithFormat(
                String(localized: "dialog.runURL.error.empty", defaultValue: "The %@ parameter cannot be empty."),
                parameter
            )
        case .valueTooLong(let parameter, let maxLength):
            return String.localizedStringWithFormat(
                String(localized: "dialog.runURL.error.tooLong", defaultValue: "The %@ parameter exceeds the %d-byte limit."),
                parameter,
                maxLength
            )
        case .unsafeCharacters(let parameter):
            return String.localizedStringWithFormat(
                String(localized: "dialog.runURL.error.unsafe", defaultValue: "The %@ parameter contains hidden or unsupported characters."),
                parameter
            )
        case .duplicateParameter(let parameter):
            return String.localizedStringWithFormat(
                String(localized: "dialog.runURL.error.duplicate", defaultValue: "The %@ parameter appears more than once."),
                parameter
            )
        case .unsupportedParameter(let parameter):
            return String.localizedStringWithFormat(
                String(localized: "dialog.runURL.error.unsupported", defaultValue: "The %@ parameter is not supported."),
                parameter
            )
        case .invalidPlacement:
            return String(localized: "dialog.runURL.error.placement", defaultValue: "The placement must be workspace, surface, or pane.")
        case .invalidDirection:
            return String(localized: "dialog.runURL.error.direction", defaultValue: "A pane direction must be left, right, up, or down.")
        case .invalidIdentifier(let parameter):
            return String.localizedStringWithFormat(
                String(localized: "dialog.runURL.error.identifier", defaultValue: "The %@ parameter is not a valid UUID."),
                parameter
            )
        case .invalidTargetCombination:
            return String(localized: "dialog.runURL.error.targetCombination", defaultValue: "The placement and target parameters are inconsistent.")
        case .multipleLinks:
            return String(localized: "dialog.runURL.error.multiple", defaultValue: "cmux accepts only one external command link at a time.")
        }
    }

    private func executionFailureMessage(_ error: CmuxRunURLExecutionError) -> String {
        switch error {
        case .busy:
            return String(localized: "dialog.runURL.error.busy", defaultValue: "Another external command request is already awaiting approval.")
        case .workingDirectoryContainsUnsafeCharacters:
            return String(
                localized: "dialog.runURL.error.directoryUnsafe",
                defaultValue: "The resolved working directory contains hidden or unsupported characters."
            )
        case .workingDirectoryContainsSurroundingWhitespace:
            return String(
                localized: "dialog.runURL.error.directoryWhitespace",
                defaultValue: "The working directory cannot start or end with whitespace."
            )
        case .workingDirectoryMustBeAbsolute:
            return String(localized: "dialog.runURL.error.absoluteDirectory", defaultValue: "The working directory must be an absolute path or start with ~.")
        case .workingDirectoryNotFound:
            return String(localized: "dialog.runURL.error.directoryNotFound", defaultValue: "The working directory does not exist or is not a directory.")
        case .workingDirectoryResolutionTimedOut:
            return String(
                localized: "dialog.runURL.error.directoryTimeout",
                defaultValue: "The working directory could not be verified before the request timed out."
            )
        case .workingDirectoryVerifierUnavailable:
            return String(
                localized: "dialog.runURL.error.verifierUnavailable",
                defaultValue: "The previous directory check is still stopping. Wait and try again. If this continues, restart cmux."
            )
        case .targetNotFound:
            return String(localized: "dialog.runURL.error.targetNotFound", defaultValue: "The requested cmux window, workspace, pane, or surface is no longer available.")
        case .remoteWorkspaceUnsupported:
            return String(localized: "dialog.runURL.error.remote", defaultValue: "Command links can target only local workspaces. Remote and tmux-mirrored workspaces are blocked.")
        case .emptyPane:
            return String(localized: "dialog.runURL.error.emptyPane", defaultValue: "The requested pane has no surface that can anchor a split.")
        case .targetChanged:
            return String(localized: "dialog.runURL.error.changed", defaultValue: "The approved directory or target changed before execution, so cmux did not run the command.")
        case .creationFailed:
            return String(localized: "dialog.runURL.error.creation", defaultValue: "cmux could not create the requested terminal, so it did not run the command.")
        }
    }
}
