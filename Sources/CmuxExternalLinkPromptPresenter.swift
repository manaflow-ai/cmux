import AppKit
import CmuxRemoteWorkspace
import Foundation

/// Builds and runs the SSH/text external-deep-link confirmation `NSAlert`s plus
/// their accessory `NSView`s and the trust-checkbox gate.
///
/// This presentation stays in the app target: it constructs `NSAlert`/`NSView`
/// AppKit objects and resolves every label with `String(localized:)`, which must
/// bind to the app bundle so the Japanese translations resolve (resolving them in
/// a package would bind to the package bundle and drop the non-English copy). The
/// control socket the `cmux ssh` command preview targets is owned by the live
/// `TerminalController`, so it is injected as ``resolveSSHURLSocketPath`` rather
/// than reached for here.
@MainActor
final class CmuxExternalLinkPromptPresenter {
    /// Holds the trust checkbox's enable/disable wiring for an SSH confirmation
    /// alert. AppKit target-action requires an `NSObject` receiver, so the gate
    /// keeps a weak reference to the Connect button and toggles it from the
    /// checkbox's `@objc` action.
    private final class ConfirmationGate: NSObject {
        weak var connectButton: NSButton?

        @objc func checkboxChanged(_ sender: NSButton) {
            connectButton?.isEnabled = sender.state == .on
        }
    }

    private let resolveSSHURLSocketPath: @MainActor () -> String

    /// - Parameter resolveSSHURLSocketPath: Resolves the control socket path the
    ///   bundled `cmux ssh` CLI should target, for the SSH command preview. Injected
    ///   because it reads live `TerminalController` socket state owned by the app.
    init(resolveSSHURLSocketPath: @escaping @MainActor () -> String) {
        self.resolveSSHURLSocketPath = resolveSSHURLSocketPath
    }

    /// Presents the SSH-launch confirmation alert. Returns `true` only when the
    /// user trusts the target (checkbox on) and presses Open.
    func confirmSSHURLRequest(_ request: CmuxSSHURLRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.sshURL.title",
            defaultValue: "Open SSH Workspace in cmux?"
        )
        alert.informativeText = String(
            format: String(
                localized: "dialog.sshURL.message",
                defaultValue: "An external link wants to open \"%@\" in cmux. Do you want to open this SSH workspace?\n\nIf you did not initiate this request, it may represent an attempted attack on your system. Only continue if you explicitly started this action."
            ),
            request.displayTarget
        )

        let cancelTitle = String(localized: "dialog.sshURL.cancel", defaultValue: "No")
        let runTitle = String(localized: "dialog.sshURL.run", defaultValue: "Open")
        alert.addButton(withTitle: cancelTitle)
        alert.addButton(withTitle: runTitle)

        let cancelButton = alert.buttons[0]
        cancelButton.keyEquivalent = "\r"
        if alert.buttons.count > 1 {
            let connectButton = alert.buttons[1]
            connectButton.keyEquivalent = ""
            connectButton.isEnabled = false
        }

        let gate = ConfirmationGate()
        if alert.buttons.count > 1 {
            gate.connectButton = alert.buttons[1]
        }
        alert.accessoryView = sshURLAccessoryView(request: request, gate: gate)
        let response: NSApplication.ModalResponse = withExtendedLifetime(gate) {
            alert.runModal()
        }
        return response == .alertSecondButtonReturn
    }

    /// Presents the text-paste (prompt/rules) confirmation alert. Returns `true`
    /// only when the user presses Paste.
    func confirmTextURLRequest(_ request: CmuxTextURLRequest) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.kind == .prompt
            ? String(localized: "dialog.textURL.prompt.title", defaultValue: "Paste a Prompt From an External Link?")
            : String(localized: "dialog.textURL.rules.title", defaultValue: "Paste Rules From an External Link?")

        let scheme = request.originalURL.scheme ?? AuthEnvironment.callbackScheme
        let messageFormat = request.kind == .prompt
            ? String(
                localized: "dialog.textURL.prompt.message",
                defaultValue: "A %@:// link is asking cmux to paste a prompt into the current workspace. cmux cannot verify which website or app opened this link.\n\ncmux will paste the text into the terminal and will not press Return. Only continue if you trust this prompt."
            )
            : String(
                localized: "dialog.textURL.rules.message",
                defaultValue: "A %@:// link is asking cmux to paste rules into the current workspace. cmux cannot verify which website or app opened this link.\n\ncmux will paste the rules into the terminal and will not write files or press Return. Only continue if you trust these rules."
            )
        alert.informativeText = String(
            format: messageFormat,
            scheme
        )

        alert.addButton(withTitle: String(localized: "dialog.textURL.cancel", defaultValue: "Cancel"))
        alert.addButton(withTitle: String(localized: "dialog.textURL.paste", defaultValue: "Paste"))

        let cancelButton = alert.buttons[0]
        cancelButton.keyEquivalent = "\r"
        if alert.buttons.count > 1 {
            alert.buttons[1].keyEquivalent = ""
        }

        alert.accessoryView = textURLAccessoryView(request: request)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func sshURLAccessoryView(
        request: CmuxSSHURLRequest,
        gate: ConfirmationGate
    ) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let targetLabel = NSTextField(labelWithString: String(
            format: String(localized: "dialog.sshURL.targetLabel", defaultValue: "SSH target: %@"),
            request.displayTarget
        ))
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.maximumNumberOfLines = 1

        let commandLabel = NSTextField(labelWithString: String(
            localized: "dialog.sshURL.commandLabel",
            defaultValue: "Command preview:"
        ))
        commandLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)

        let socketPath = resolveSSHURLSocketPath()
        let commandScrollView = sshURLTextPreview(request.cliPreview(socketPath: socketPath), height: 80)

        stack.addArrangedSubview(targetLabel)
        stack.addArrangedSubview(commandLabel)
        stack.addArrangedSubview(commandScrollView)

        let checkbox = NSButton(
            checkboxWithTitle: String(
                localized: "dialog.sshURL.checkbox",
                defaultValue: "I trust this SSH target and want cmux to connect."
            ),
            target: gate,
            action: #selector(ConfirmationGate.checkboxChanged(_:))
        )
        checkbox.lineBreakMode = .byWordWrapping
        stack.addArrangedSubview(checkbox)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 156))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            targetLabel.widthAnchor.constraint(equalTo: container.widthAnchor),
            commandScrollView.widthAnchor.constraint(equalTo: container.widthAnchor),
            checkbox.widthAnchor.constraint(equalTo: container.widthAnchor)
        ])
        return container
    }

    private func textURLAccessoryView(request: CmuxTextURLRequest) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let localizedKind = request.kind == .prompt
            ? String(localized: "dialog.textURL.kind.prompt", defaultValue: "Prompt")
            : String(localized: "dialog.textURL.kind.rules", defaultValue: "Rules")
        let displayTitle = request.name ?? request.title
        let kindLabel = NSTextField(labelWithString: String(
            format: String(localized: "dialog.textURL.kindLabel", defaultValue: "Link type: %@"),
            localizedKind
        ))
        kindLabel.lineBreakMode = .byTruncatingTail
        kindLabel.maximumNumberOfLines = 1

        let titleLabel = displayTitle.map { displayTitle in
            let label = NSTextField(labelWithString: String(
                format: String(localized: "dialog.textURL.titleLabel", defaultValue: "Title: %@"),
                displayTitle
            ))
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            return label
        }

        let previewLabel = NSTextField(labelWithString: String(
            localized: "dialog.textURL.previewLabel",
            defaultValue: "Text preview:"
        ))
        previewLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)

        let preview = sshURLTextPreview(request.pasteText, height: 180)

        stack.addArrangedSubview(kindLabel)
        if let titleLabel {
            stack.addArrangedSubview(titleLabel)
        }
        stack.addArrangedSubview(previewLabel)
        stack.addArrangedSubview(preview)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 238))
        container.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            kindLabel.widthAnchor.constraint(equalTo: container.widthAnchor),
            preview.widthAnchor.constraint(equalTo: container.widthAnchor)
        ]
        if let titleLabel {
            constraints.append(titleLabel.widthAnchor.constraint(equalTo: container.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    private func sshURLTextPreview(_ text: String, height: CGFloat) -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: height))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.heightAnchor.constraint(equalToConstant: height)
        ])
        return scrollView
    }
}
