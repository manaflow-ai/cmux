import AppKit
import CmuxSocketControl
import Bonsplit
import Foundation
import UniformTypeIdentifiers

@MainActor
private final class CmuxSSHURLConfirmationGate: NSObject {
    weak var connectButton: NSButton?

    @objc func checkboxChanged(_ sender: NSButton) {
        connectButton?.isEnabled = sender.state == .on
    }
}

extension AppDelegate {
    @discardableResult
    func handleCmuxSSHURLs(from urls: [URL]) -> Bool {
        var sshURLRequests: [CmuxSSHURLRequest] = []
        var sshURLParseErrors: [CmuxSSHURLParseError] = []
        for url in urls {
            switch CmuxSSHURLRequest.parse(url) {
            case .success(.some(let request)):
                sshURLRequests.append(request)
            case .success(nil):
                break
            case .failure(let error):
                sshURLParseErrors.append(error)
            }
        }
        let sshURLIntentCount = sshURLRequests.count + sshURLParseErrors.count
        guard sshURLIntentCount > 0 else { return false }

        if sshURLIntentCount > 1 {
            showCmuxSSHURLParseError(.multipleLinks)
        } else {
            for error in sshURLParseErrors {
                showCmuxSSHURLParseError(error)
            }
            if let request = sshURLRequests.first {
                handleCmuxSSHURLRequest(request)
            }
        }
        return true
    }

    private func handleCmuxSSHURLRequest(_ request: CmuxSSHURLRequest) {
#if DEBUG
        let target = request.originalURL.host ?? request.originalURL.path
        cmuxDebugLog("sshURL.prompt target=\(target) destinationLength=\(request.destination.count) hasPort=\(request.port != nil)")
#endif

        deferInitialMainWindowBootstrapForExternalConfirmation()
        guard confirmCmuxSSHURLRequest(request) else {
            resumeInitialMainWindowBootstrapAfterExternalConfirmation(debugSource: "sshURL.cancelled")
#if DEBUG
            cmuxDebugLog("sshURL.cancelled")
#endif
            return
        }

        prepareForExplicitOpenIntentAtStartup()
        bootstrapInitialMainWindowAfterAcceptedExternalOpen(debugSource: "sshURL.confirmed")
        NSApp.activate(ignoringOtherApps: true)
        _ = CmuxSSHURLProcessLauncher.shared.start(
            request: request,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    private func confirmCmuxSSHURLRequest(_ request: CmuxSSHURLRequest) -> Bool {
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

        let gate = CmuxSSHURLConfirmationGate()
        if alert.buttons.count > 1 {
            gate.connectButton = alert.buttons[1]
        }
        alert.accessoryView = cmuxSSHURLAccessoryView(request: request, gate: gate)
        let response: NSApplication.ModalResponse = withExtendedLifetime(gate) {
            alert.runModal()
        }
        return response == .alertSecondButtonReturn
    }

    private func cmuxSSHURLAccessoryView(
        request: CmuxSSHURLRequest,
        gate: CmuxSSHURLConfirmationGate
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

        let socketPath = CmuxSSHURLProcessLauncher.shared.resolvedSocketPath()
        let commandScrollView = cmuxSSHURLTextPreview(request.cliPreview(socketPath: socketPath), height: 80)

        stack.addArrangedSubview(targetLabel)
        stack.addArrangedSubview(commandLabel)
        stack.addArrangedSubview(commandScrollView)

        let checkbox = NSButton(
            checkboxWithTitle: String(
                localized: "dialog.sshURL.checkbox",
                defaultValue: "I trust this SSH target and want cmux to connect."
            ),
            target: gate,
            action: #selector(CmuxSSHURLConfirmationGate.checkboxChanged(_:))
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

    func cmuxSSHURLTextPreview(_ text: String, height: CGFloat) -> NSScrollView {
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

    func showCmuxSSHURLParseError(_ error: CmuxSSHURLParseError) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "dialog.sshURL.blocked.title",
            defaultValue: "cmux SSH Link Blocked"
        )
        alert.informativeText = cmuxSSHURLParseErrorMessage(error)
        alert.addButton(withTitle: String(localized: "dialog.sshURL.blocked.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private func cmuxSSHURLParseErrorMessage(_ error: CmuxSSHURLParseError) -> String {
        switch error {
        case .missingDestination:
            return String(
                localized: "dialog.sshURL.error.missingDestination",
                defaultValue: "The link did not include an SSH host."
            )
        case .destinationTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.sshURL.error.destinationTooLong", defaultValue: "The SSH target is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .destinationContainsUnsafeCharacters:
            return String(
                localized: "dialog.sshURL.error.destinationContainsUnsafeCharacters",
                defaultValue: "The SSH host or user contains unsupported or hidden characters, so cmux refused to use it."
            )
        case .destinationStartsWithDash:
            return String(
                localized: "dialog.sshURL.error.destinationStartsWithDash",
                defaultValue: "The SSH host or user cannot start with a dash."
            )
        case .titleTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.sshURL.error.titleTooLong", defaultValue: "The workspace title is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .titleContainsUnsafeCharacters:
            return String(
                localized: "dialog.sshURL.error.titleContainsControlCharacters",
                defaultValue: "The workspace title contains hidden control or formatting characters, so cmux refused to use it."
            )
        case .invalidPort:
            return String(
                localized: "dialog.sshURL.error.invalidPort",
                defaultValue: "The SSH port must be between 1 and 65535."
            )
        case .invalidIntegerParameter(let parameter):
            return String(
                format: String(localized: "dialog.sshURL.error.invalidIntegerParameter", defaultValue: "The SSH link included an invalid integer value for parameter: %@"),
                parameter
            )
        case .invalidHostKeyPolicy(let parameter):
            return String(
                format: String(localized: "dialog.sshURL.error.invalidHostKeyPolicy", defaultValue: "The SSH link included an invalid host key policy for parameter: %@"),
                parameter
            )
        case .invalidBooleanParameter(let parameter):
            return String(
                format: String(localized: "dialog.sshURL.error.invalidBooleanParameter", defaultValue: "The SSH link included an invalid boolean value for parameter: %@"),
                parameter
            )
        case .conflictingDestinationParameters:
            return String(
                localized: "dialog.sshURL.error.conflictingDestinationParameters",
                defaultValue: "The link included conflicting SSH target fields."
            )
        case .conflictingTitleParameters:
            return String(
                localized: "dialog.sshURL.error.conflictingTitleParameters",
                defaultValue: "The link included both title and name. Use only one workspace title field."
            )
        case .duplicateParameter(let parameter):
            return String(
                format: String(localized: "dialog.sshURL.error.duplicateParameter", defaultValue: "The SSH link repeated a parameter: %@"),
                parameter
            )
        case .unsupportedParameter(let parameter):
            return String(
                format: String(localized: "dialog.sshURL.error.unsupportedParameter", defaultValue: "The SSH link included an unsupported parameter: %@"),
                parameter
            )
        case .multipleLinks:
            return String(
                localized: "dialog.sshURL.error.multipleLinks",
                defaultValue: "Only one SSH link can be opened at a time."
            )
        }
    }

}
