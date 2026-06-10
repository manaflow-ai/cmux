import AppKit
import CmuxSocketControl
import Bonsplit
import Foundation
import UniformTypeIdentifiers


// MARK: - Text URL Handling
extension AppDelegate {
    @discardableResult
    func handleCmuxTextURLs(from urls: [URL]) -> Bool {
        var textURLRequests: [CmuxTextURLRequest] = []
        var textURLParseErrors: [CmuxTextURLParseError] = []
        for url in urls {
            switch CmuxTextURLRequest.parse(url) {
            case .success(.some(let request)):
                textURLRequests.append(request)
            case .success(nil):
                break
            case .failure(let error):
                textURLParseErrors.append(error)
            }
        }
        let textURLIntentCount = textURLRequests.count + textURLParseErrors.count
        guard textURLIntentCount > 0 else { return false }

        if textURLIntentCount > 1 {
            showCmuxTextURLParseError(.multipleLinks)
        } else {
            for error in textURLParseErrors {
                showCmuxTextURLParseError(error)
            }
            if let request = textURLRequests.first {
                handleCmuxTextURLRequest(request)
            }
        }
        return true
    }

    private func handleCmuxTextURLRequest(_ request: CmuxTextURLRequest) {
#if DEBUG
        let target = request.originalURL.host ?? request.originalURL.path
        cmuxDebugLog("textURL.prompt target=\(target) kind=\(request.kind.rawValue) textLength=\(request.text.count)")
#endif

        deferInitialMainWindowBootstrapForExternalConfirmation()
        guard confirmCmuxTextURLRequest(request) else {
            resumeInitialMainWindowBootstrapAfterExternalConfirmation(debugSource: "textURL.cancelled")
#if DEBUG
            cmuxDebugLog("textURL.cancelled")
#endif
            return
        }

        prepareForExplicitOpenIntentAtStartup()
        bootstrapInitialMainWindowAfterAcceptedExternalOpen(
            debugSource: "textURL.confirmed",
            shouldActivate: !request.noFocus,
            suppressWelcome: true
        )
        if !request.noFocus {
            NSApp.activate(ignoringOtherApps: true)
        }
        let didPaste = pasteTextInPreferredMainWindowFromExternalLink(
            request.pasteText,
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow,
            shouldBringToFront: !request.noFocus,
            debugSource: "textURL.\(request.kind.rawValue)",
            onSendFailure: { [weak self] in
                self?.showCmuxTextURLPasteFailure(request)
            }
        )
        if !didPaste {
            showCmuxTextURLPasteFailure(request)
        }
    }

    private func confirmCmuxTextURLRequest(_ request: CmuxTextURLRequest) -> Bool {
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

        alert.accessoryView = cmuxTextURLAccessoryView(request: request)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func cmuxTextURLAccessoryView(request: CmuxTextURLRequest) -> NSView {
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

        let preview = cmuxSSHURLTextPreview(request.pasteText, height: 180)

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

    private func showCmuxTextURLPasteFailure(_ request: CmuxTextURLRequest) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.kind == .prompt
            ? String(localized: "dialog.textURL.prompt.pasteFailed.title", defaultValue: "Couldn't Paste Prompt Link")
            : String(localized: "dialog.textURL.rules.pasteFailed.title", defaultValue: "Couldn't Paste Rules Link")
        alert.informativeText = String(
            localized: "dialog.textURL.pasteFailed.message",
            defaultValue: "cmux could not send the link text to a terminal."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
    }

    func showCmuxTextURLParseError(_ error: CmuxTextURLParseError) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(
            localized: "dialog.textURL.blocked.title",
            defaultValue: "cmux Link Blocked"
        )
        alert.informativeText = cmuxTextURLParseErrorMessage(error)
        alert.addButton(withTitle: String(localized: "dialog.textURL.blocked.ok", defaultValue: "OK"))
        alert.runModal()
    }

    private func cmuxTextURLParseErrorMessage(_ error: CmuxTextURLParseError) -> String {
        switch error {
        case .missingText:
            return String(
                localized: "dialog.textURL.error.missingText",
                defaultValue: "The link did not include text."
            )
        case .textTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.textURL.error.textTooLong", defaultValue: "The link text is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .textContainsUnsafeCharacters:
            return String(
                localized: "dialog.textURL.error.textContainsUnsafeCharacters",
                defaultValue: "The link text contains unsupported or hidden characters, so cmux refused to use it."
            )
        case .nameTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.textURL.error.nameTooLong", defaultValue: "The link name is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .nameContainsUnsafeCharacters:
            return String(
                localized: "dialog.textURL.error.nameContainsUnsafeCharacters",
                defaultValue: "The link name contains hidden control or formatting characters, so cmux refused to use it."
            )
        case .titleTooLong(let maxLength):
            return String(
                format: String(localized: "dialog.textURL.error.titleTooLong", defaultValue: "The link title is too long. The maximum length is %lld characters."),
                maxLength
            )
        case .titleContainsUnsafeCharacters:
            return String(
                localized: "dialog.textURL.error.titleContainsUnsafeCharacters",
                defaultValue: "The link title contains hidden control or formatting characters, so cmux refused to use it."
            )
        case .invalidBooleanParameter(let parameter):
            return String(
                format: String(localized: "dialog.textURL.error.invalidBooleanParameter", defaultValue: "The link included an invalid boolean value for parameter: %@"),
                parameter
            )
        case .duplicateParameter(let parameter):
            return String(
                format: String(localized: "dialog.textURL.error.duplicateParameter", defaultValue: "The link repeated a parameter: %@"),
                parameter
            )
        case .unsupportedParameter(let parameter):
            return String(
                format: String(localized: "dialog.textURL.error.unsupportedParameter", defaultValue: "The link included an unsupported parameter: %@"),
                parameter
            )
        case .multipleLinks:
            return String(
                localized: "dialog.textURL.error.multipleLinks",
                defaultValue: "Only one cmux external link can be opened at a time."
            )
        }
    }
}
