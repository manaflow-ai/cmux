public import AppKit
import CmuxFoundation
import UniformTypeIdentifiers

/// Native modal feedback composer presented from the sidebar help menu.
@MainActor
public final class SidebarFeedbackComposerSheet: NSViewController, NSTextFieldDelegate {
    private static let formMaxHeight: CGFloat = 560

    private let settings: FeedbackComposerSettings
    private let userDefaults: UserDefaults
    private var attachments: [FeedbackComposerAttachment] = []
    private var isSubmitting = false
    private var didSend = false
    private var submissionTask: Task<Void, Never>?
    private var attachmentSelectionTask: Task<Void, Never>?
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

    private let rootStack = NSStackView()
    private let contentContainer = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let emailField = NSTextField()
    private let messageCountField = NSTextField(labelWithString: "")
    private let messageEditor = FeedbackComposerMessageEditorView()
    private let attachmentRowsStack = NSStackView()
    private let attachmentRowsContainer = NSView()
    private let errorField = NSTextField(wrappingLabelWithString: "")
    private let sendButton = NSButton()
    private let progressIndicator = NSProgressIndicator()
    private let formScrollView = NSScrollView()
    private var formStack: NSStackView?
    private var formScrollHeightConstraint: NSLayoutConstraint?

    /// Invoked when the user chooses Done or Cancel.
    public var onDismiss: (@MainActor () -> Void)?

    public init(
        settings: FeedbackComposerSettings = FeedbackComposerSettings(),
        userDefaults: UserDefaults = .standard,
        onDismiss: (@MainActor () -> Void)? = nil
    ) {
        self.settings = settings
        self.userDefaults = userDefaults
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        submissionTask?.cancel()
        attachmentSelectionTask?.cancel()
    }

    public override func loadView() {
        let rootView = NSView()
        rootView.setAccessibilityIdentifier("SidebarFeedbackDialog")
        view = rootView

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 16
        rootView.addSubview(rootStack)

        titleField.stringValue = localized("sidebar.help.feedback.title", "Send Feedback")
        titleField.lineBreakMode = .byTruncatingTail
        rootStack.addArrangedSubview(titleField)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(contentContainer)

        NSLayoutConstraint.activate([
            rootView.widthAnchor.constraint(equalToConstant: 520),
            rootStack.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 20),
            rootStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            rootStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -20),
            contentContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
        ])

        installForm()
        applyFonts()
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.applyFonts()
            self?.updateFormDocumentLayout()
        }
        updateControls()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateFormDocumentLayout()
        preferredContentSize = NSSize(width: 520, height: ceil(rootStack.fittingSize.height + 40))
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        submissionTask?.cancel()
        attachmentSelectionTask?.cancel()
    }

    private func installForm() {
        let note = makeLabel(
            localized(
                "sidebar.help.feedback.note",
                "A human will read this! You can also reach us at founders@manaflow.com."
            ),
            size: 12,
            color: .secondaryLabelColor,
            wraps: true
        )

        let emailLabel = makeLabel(
            localized("sidebar.help.feedback.email", "Your Email"),
            size: 12,
            weight: .medium
        )
        emailField.stringValue = userDefaults.string(forKey: settings.storedEmailKey) ?? ""
        emailField.placeholderString = localized(
            "sidebar.help.feedback.emailPlaceholder",
            "you@example.com"
        )
        emailField.delegate = self
        emailField.setAccessibilityLabel(localized("sidebar.help.feedback.email", "Your Email"))
        emailField.setAccessibilityIdentifier("SidebarFeedbackEmailField")
        let emailStack = verticalStack([emailLabel, emailField], spacing: 6)

        let messageLabel = makeLabel(
            localized("sidebar.help.feedback.message", "Message"),
            size: 12,
            weight: .medium
        )
        let messageHeader = horizontalRow(leading: [messageLabel], trailing: [messageCountField])
        messageEditor.placeholder = localized(
            "sidebar.help.feedback.messagePlaceholder",
            "Share feedback, feature requests, or issues."
        )
        let messageAccessibilityLabel = localized("sidebar.help.feedback.message", "Message")
        messageEditor.textView.setAccessibilityLabel(messageAccessibilityLabel)
        messageEditor.textView.setAccessibilityIdentifier("SidebarFeedbackMessageEditor")
        messageEditor.setAccessibilityIdentifier("SidebarFeedbackMessageEditor")
        messageEditor.onTextChange = { [weak self] _ in
            self?.updateControls()
        }
        messageEditor.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let messageStack = verticalStack([messageHeader, messageEditor], spacing: 6)

        let attachButton = NSButton(
            title: localized("sidebar.help.feedback.attachImages", "Attach Images"),
            target: self,
            action: #selector(chooseAttachmentsAction(_:))
        )
        attachButton.bezelStyle = .rounded
        attachButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        attachButton.imagePosition = .imageLeading
        attachButton.setAccessibilityIdentifier("SidebarFeedbackAttachButton")
        let attachmentHint = makeLabel(
            localized("sidebar.help.feedback.attachmentsHint", "Up to 10 images."),
            size: 11,
            color: .secondaryLabelColor
        )
        let attachmentHeader = horizontalRow(leading: [attachButton, attachmentHint], spacing: 10)

        attachmentRowsContainer.translatesAutoresizingMaskIntoConstraints = false
        attachmentRowsContainer.wantsLayer = true
        attachmentRowsContainer.layer?.cornerRadius = 10
        attachmentRowsContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        attachmentRowsStack.translatesAutoresizingMaskIntoConstraints = false
        attachmentRowsStack.orientation = .vertical
        attachmentRowsStack.alignment = .leading
        attachmentRowsStack.spacing = 6
        attachmentRowsContainer.addSubview(attachmentRowsStack)
        NSLayoutConstraint.activate([
            attachmentRowsStack.topAnchor.constraint(equalTo: attachmentRowsContainer.topAnchor, constant: 10),
            attachmentRowsStack.leadingAnchor.constraint(equalTo: attachmentRowsContainer.leadingAnchor, constant: 10),
            attachmentRowsStack.trailingAnchor.constraint(equalTo: attachmentRowsContainer.trailingAnchor, constant: -10),
            attachmentRowsStack.bottomAnchor.constraint(equalTo: attachmentRowsContainer.bottomAnchor, constant: -10),
            attachmentRowsStack.widthAnchor.constraint(equalTo: attachmentRowsContainer.widthAnchor, constant: -20),
        ])
        attachmentRowsContainer.isHidden = true
        let attachmentStack = verticalStack(
            [attachmentHeader, attachmentRowsContainer],
            spacing: 8
        )

        errorField.textColor = .systemRed
        errorField.isHidden = true

        let cancelButton = NSButton(
            title: localized("sidebar.help.feedback.cancel", "Cancel"),
            target: self,
            action: #selector(dismissAction(_:))
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.isHidden = true

        sendButton.title = localized("sidebar.help.feedback.send", "Send")
        sendButton.target = self
        sendButton.action = #selector(submitAction(_:))
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.setAccessibilityIdentifier("SidebarFeedbackSendButton")

        let actions = horizontalRow(
            trailing: [progressIndicator, cancelButton, sendButton],
            spacing: 8
        )

        let form = verticalStack(
            [note, emailStack, messageStack, attachmentStack, errorField, actions],
            spacing: 14
        )
        form.setFrameSize(NSSize(width: 476, height: form.fittingSize.height))
        formStack = form

        formScrollView.translatesAutoresizingMaskIntoConstraints = false
        formScrollView.borderType = .noBorder
        formScrollView.drawsBackground = false
        formScrollView.hasHorizontalScroller = false
        formScrollView.hasVerticalScroller = true
        formScrollView.autohidesScrollers = true
        formScrollView.scrollerStyle = .overlay
        formScrollView.documentView = form

        replaceContent(with: formScrollView)
        let height = min(max(ceil(form.fittingSize.height), 1), Self.formMaxHeight)
        let heightConstraint = formScrollView.heightAnchor.constraint(equalToConstant: height)
        heightConstraint.isActive = true
        formScrollHeightConstraint = heightConstraint
    }

    private func installSuccess() {
        didSend = true
        let successTitle = makeLabel(
            localized("sidebar.help.feedback.successTitle", "Thanks for the feedback."),
            size: 13,
            weight: .semibold
        )
        let successBody = makeLabel(
            localized(
                "sidebar.help.feedback.successBody",
                "You can also reach us at founders@manaflow.com."
            ),
            size: 12,
            color: .secondaryLabelColor,
            wraps: true
        )
        successBody.isSelectable = true

        let doneButton = NSButton(
            title: localized("sidebar.help.feedback.done", "Done"),
            target: self,
            action: #selector(dismissAction(_:))
        )
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        let actions = horizontalRow(trailing: [doneButton])
        let successStack = verticalStack([successTitle, successBody, actions], spacing: 12)
        replaceContent(with: successStack)
        applyFonts()
        view.needsLayout = true
    }

    private func replaceContent(with content: NSView) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            content.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        views.forEach { view in
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func horizontalRow(
        leading: [NSView] = [],
        trailing: [NSView] = [],
        spacing: CGFloat = 8
    ) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: leading + [spacer] + trailing)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        wraps: Bool = false
    ) -> NSTextField {
        FeedbackLabel(
            text: text,
            size: size,
            weight: weight,
            color: color,
            wraps: wraps
        )
    }

    private func applyFonts() {
        titleField.font = GlobalFontMagnification.systemFont(ofSize: 15, weight: .semibold)
        messageCountField.font = GlobalFontMagnification.systemFont(ofSize: 11)
        errorField.font = GlobalFontMagnification.systemFont(ofSize: 12)
        applyFontRecursively(to: contentContainer)
    }

    private func applyFontRecursively(to view: NSView) {
        for subview in view.subviews {
            if let field = subview as? FeedbackLabel {
                field.applyFont()
            }
            applyFontRecursively(to: subview)
        }
        emailField.font = GlobalFontMagnification.systemFont(ofSize: 12)
    }

    private func updateFormDocumentLayout() {
        guard let formStack else { return }
        let width = max(formScrollView.contentSize.width - 4, 1)
        formStack.setFrameSize(NSSize(width: width, height: formStack.frame.height))
        formStack.layoutSubtreeIfNeeded()
        let documentHeight = max(ceil(formStack.fittingSize.height), 1)
        formStack.setFrameSize(NSSize(width: width, height: documentHeight))
        let visibleHeight = min(documentHeight, Self.formMaxHeight)
        if abs((formScrollHeightConstraint?.constant ?? 0) - visibleHeight) > 0.5 {
            formScrollHeightConstraint?.constant = visibleHeight
        }
    }

    public func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === emailField else { return }
        userDefaults.set(emailField.stringValue, forKey: settings.storedEmailKey)
        updateControls()
    }

    private func updateControls() {
        let message = messageEditor.textView.string
        messageCountField.stringValue = "\(message.count)/\(settings.maxMessageLength)"
        messageCountField.textColor = message.count > settings.maxMessageLength
            ? .systemRed
            : .secondaryLabelColor
        sendButton.isEnabled = isValidEmail(emailField.stringValue)
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && message.count <= settings.maxMessageLength
            && !isSubmitting
            && !didSend
    }

    @objc
    private func chooseAttachmentsAction(_ sender: Any?) {
        attachmentSelectionTask?.cancel()
        attachmentSelectionTask = Task { [weak self] in
            await self?.chooseAttachments()
        }
    }

    private func chooseAttachments() async {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.title = localized("sidebar.help.feedback.attachImages.title", "Attach Images")
        panel.prompt = localized("sidebar.help.feedback.attachImages.prompt", "Attach")

        let response = await panel.beginSheetModal(for: window)
        guard response == .OK, !Task.isCancelled else { return }

        var updatedAttachments = attachments
        var knownPaths = Set(updatedAttachments.map(\.standardizedPath))
        var firstIssue: String?

        for url in panel.urls {
            let normalizedPath = url.standardizedFileURL.path
            if knownPaths.contains(normalizedPath) {
                continue
            }
            if updatedAttachments.count >= settings.maxAttachmentCount {
                firstIssue = localized(
                    "sidebar.help.feedback.tooManyImages",
                    "You can attach up to 10 images."
                )
                break
            }

            guard let attachment = try? FeedbackComposerAttachment(url: url) else {
                firstIssue = localized(
                    "sidebar.help.feedback.invalidImageSelection",
                    "One of the selected files could not be attached."
                )
                continue
            }
            updatedAttachments.append(attachment)
            knownPaths.insert(normalizedPath)
        }

        attachments = updatedAttachments
        setSubmissionError(firstIssue)
        rebuildAttachmentRows()
    }

    private func rebuildAttachmentRows() {
        attachmentRowsStack.arrangedSubviews.forEach { view in
            attachmentRowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for attachment in attachments {
            let icon = NSImageView(
                image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage()
            )
            icon.contentTintColor = .secondaryLabelColor
            let name = makeLabel(attachment.fileName, size: 12)
            name.lineBreakMode = .byTruncatingMiddle
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let size = makeLabel(attachment.displaySize, size: 11, color: .secondaryLabelColor)
            let remove = AttachmentRemoveButton(
                title: localized("sidebar.help.feedback.removeAttachment", "Remove"),
                target: self,
                action: #selector(removeAttachmentAction(_:))
            )
            remove.attachmentID = attachment.id
            remove.isBordered = false
            remove.contentTintColor = .linkColor
            remove.setAccessibilityLabel(
                "\(localized("sidebar.help.feedback.removeAttachment", "Remove")) \(attachment.fileName)"
            )
            let row = horizontalRow(leading: [icon, name], trailing: [size, remove], spacing: 8)
            row.widthAnchor.constraint(equalTo: attachmentRowsStack.widthAnchor).isActive = true
            attachmentRowsStack.addArrangedSubview(row)
        }

        attachmentRowsContainer.isHidden = attachments.isEmpty
        updateFormDocumentLayout()
    }

    @objc
    private func removeAttachmentAction(_ sender: AttachmentRemoveButton) {
        attachments.removeAll { $0.id == sender.attachmentID }
        setSubmissionError(nil)
        rebuildAttachmentRows()
    }

    @objc
    private func submitAction(_ sender: Any?) {
        submissionTask?.cancel()
        submissionTask = Task { [weak self] in
            await self?.submitFeedback()
        }
    }

    private func submitFeedback() async {
        let trimmedEmail = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = messageEditor.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidEmail(trimmedEmail) else {
            setSubmissionError(localized("sidebar.help.feedback.invalidEmail", "Enter a valid email address."))
            return
        }
        guard !normalizedMessage.isEmpty else {
            setSubmissionError(localized("sidebar.help.feedback.emptyMessage", "Enter a message before sending."))
            return
        }
        guard messageEditor.textView.string.count <= settings.maxMessageLength else {
            setSubmissionError(localized("sidebar.help.feedback.messageTooLong", "Your message is too long."))
            return
        }

        emailField.stringValue = trimmedEmail
        userDefaults.set(trimmedEmail, forKey: settings.storedEmailKey)
        setSubmissionError(nil)
        isSubmitting = true
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        updateControls()

        do {
            try await FeedbackComposerClient(settings: settings).submit(
                email: trimmedEmail,
                message: normalizedMessage,
                attachments: attachments
            )
            guard !Task.isCancelled else { return }
            finishSubmission()
            attachments = []
            installSuccess()
        } catch {
            guard !Task.isCancelled else { return }
            finishSubmission()
            setSubmissionError(userFacingErrorMessage(for: error))
        }
    }

    private func finishSubmission() {
        isSubmitting = false
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        updateControls()
    }

    private func setSubmissionError(_ message: String?) {
        errorField.stringValue = message ?? ""
        errorField.isHidden = message?.isEmpty != false
        updateFormDocumentLayout()
    }

    @objc
    private func dismissAction(_ sender: Any?) {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss(sender)
        }
    }

    private func isValidEmail(_ rawValue: String) -> Bool {
        let email = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return false }
        let pattern = #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#
        return NSPredicate(format: "SELF MATCHES %@", pattern).evaluate(with: email)
    }

    private func userFacingErrorMessage(for error: any Error) -> String {
        guard let submissionError = error as? FeedbackComposerSubmissionError else {
            return localized(
                "sidebar.help.feedback.genericError",
                "Couldn't send feedback. Please try again."
            )
        }

        switch submissionError {
        case .invalidEndpoint:
            return localized(
                "sidebar.help.feedback.endpointError",
                "Feedback is unavailable right now. Email founders@manaflow.com instead."
            )
        case .invalidResponse:
            return localized(
                "sidebar.help.feedback.genericError",
                "Couldn't send feedback. Please try again."
            )
        case .attachmentReadFailed:
            return localized(
                "sidebar.help.feedback.invalidImageSelection",
                "One of the selected files could not be attached."
            )
        case .attachmentPreparationFailed:
            return localized(
                "sidebar.help.feedback.totalImagesTooLarge",
                "These images are too large to send together. Remove a few and try again."
            )
        case .transport(let transportError):
            if transportError.code == .notConnectedToInternet || transportError.code == .networkConnectionLost {
                return localized(
                    "sidebar.help.feedback.connectionError",
                    "Couldn't send feedback. Check your connection and try again."
                )
            }
            return localized(
                "sidebar.help.feedback.genericError",
                "Couldn't send feedback. Please try again."
            )
        case .rejected(let statusCode):
            switch statusCode {
            case 400, 413, 415:
                return localized(
                    "sidebar.help.feedback.validationError",
                    "Check your message and attachments, then try again."
                )
            case 429:
                return localized(
                    "sidebar.help.feedback.rateLimited",
                    "Too many feedback attempts. Please try again later."
                )
            case 500...599:
                return localized(
                    "sidebar.help.feedback.endpointError",
                    "Feedback is unavailable right now. Email founders@manaflow.com instead."
                )
            default:
                return localized(
                    "sidebar.help.feedback.genericError",
                    "Couldn't send feedback. Please try again."
                )
            }
        }
    }

    private func localized(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }
}

@MainActor
private final class AttachmentRemoveButton: NSButton {
    var attachmentID: UUID?
}

@MainActor
private final class FeedbackLabel: NSTextField {
    private let baseSize: CGFloat
    private let fontWeight: NSFont.Weight

    init(
        text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        wraps: Bool
    ) {
        baseSize = size
        fontWeight = weight
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = wraps ? .byWordWrapping : .byClipping
        maximumNumberOfLines = wraps ? 0 : 1
        textColor = color
        applyFont()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyFont() {
        font = GlobalFontMagnification.systemFont(ofSize: baseSize, weight: fontWeight)
    }
}
