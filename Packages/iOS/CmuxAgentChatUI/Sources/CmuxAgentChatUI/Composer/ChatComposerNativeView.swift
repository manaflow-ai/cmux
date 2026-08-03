#if os(iOS)
import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileSupport
import Observation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct ChatComposerNativeConfiguration {
    let agentState: ChatAgentState
    let agentKind: ChatAgentKind
    let isTerminal: Bool
    let isConnected: Bool
    let accessoryLeadingShortcuts: [ChatAccessoryShortcut]
    let accessoryShortcuts: [ChatAccessoryShortcut]
    let draft: String
    let setDraft: @MainActor (String) -> Void
    let onSend: @MainActor (String, [ChatOutboundAttachment]) -> Void
    let onInterrupt: @MainActor (Bool) -> Void
    let onOpenTerminal: @MainActor () -> Void
}

/// Native mobile composer with structured attachment staging and observable dictation.
@MainActor
final class ChatComposerNativeView: UIView,
    UITextViewDelegate,
    PHPickerViewControllerDelegate
{
    private static let maxAttachmentDimension: CGFloat = 2_048
    private static let jpegQuality: CGFloat = 0.85
    private static let hardStopWindow: TimeInterval = 2
    private static let minimumFieldHeight: CGFloat = 40

    var onIntrinsicHeightChanged: @MainActor () -> Void = {}

    private var configuration: ChatComposerNativeConfiguration
    private let dictation = ComposerDictationController()
    private var lastStopTap: Date?
    private var attachments: [ChatComposerAttachment] = []
    private var attachmentStagingTask: Task<Void, Never>?
    private var isStagingAttachments = false

    private let rootStack = UIStackView()
    private let accessoryRow = ChatAccessoryChipRowNativeView()
    private let attachmentScroll = UIScrollView()
    private let attachmentStack = UIStackView()
    private let fieldRow = UIStackView()
    private let attachButton = UIButton(type: .system)
    private let micButton = UIButton(type: .system)
    private let fieldBackground = UIVisualEffectView(effect: nil)
    private let fieldContent = UIStackView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private var textHeightConstraint: NSLayoutConstraint?

    init(configuration: ChatComposerNativeConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        configureViews()
        observeDictation()
        update(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(configuration: ChatComposerNativeConfiguration) {
        self.configuration = configuration
        if textView.text != configuration.draft {
            textView.text = configuration.draft
        }
        textView.font = configuration.isTerminal
            ? .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                weight: .regular
            )
            : .preferredFont(forTextStyle: .body)
        placeholderLabel.font = textView.font
        placeholderLabel.text = placeholder
        placeholderLabel.isHidden = !configuration.draft.isEmpty
        accessoryRow.update(
            agentState: configuration.agentState,
            leadingShortcuts: remapped(configuration.accessoryLeadingShortcuts),
            shortcuts: remapped(configuration.accessoryShortcuts),
            onInterrupt: configuration.onInterrupt,
            onOpenTerminal: configuration.onOpenTerminal
        )
        updateSendButton()
        updateMicButton()
        updateTextHeight()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            dictation.cancel()
            attachmentStagingTask?.cancel()
            attachmentStagingTask = nil
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        configuration.setDraft(textView.text)
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateTextHeight()
        updateSendButton()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if !dictation.locksComposerField {
            dictation.stop()
        }
    }

    func picker(
        _ picker: PHPickerViewController,
        didFinishPicking results: [PHPickerResult]
    ) {
        picker.dismiss(animated: true)
        attachmentStagingTask?.cancel()
        isStagingAttachments = true
        updateSendButton()
        attachmentStagingTask = Task { [weak self] in
            var staged: [ChatComposerAttachment] = []
            for (index, result) in results.prefix(4).enumerated() {
                guard !Task.isCancelled,
                      let data = await result.itemProvider.chatComposerImageData(),
                      let attachment = data.chatComposerImageAttachment(
                          id: result.assetIdentifier ?? "picked-\(index)",
                          maxDimension: Self.maxAttachmentDimension,
                          jpegQuality: Self.jpegQuality
                      ) else { continue }
                staged.append(attachment)
            }
            guard !Task.isCancelled, let self else { return }
            self.attachments = staged
            self.isStagingAttachments = false
            self.attachmentStagingTask = nil
            self.rebuildAttachmentStrip()
            self.updateSendButton()
            self.invalidateComposerHeight()
        }
    }

    private func configureViews() {
        accessibilityIdentifier = "ChatComposerBar"
        accessibilityContainerType = .semanticGroup

        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 8
        rootStack.isLayoutMarginsRelativeArrangement = true
        rootStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 2,
            leading: 12,
            bottom: 8,
            trailing: 12
        )
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rootStack.addArrangedSubview(accessoryRow)

        attachmentScroll.showsHorizontalScrollIndicator = false
        attachmentScroll.isDirectionalLockEnabled = true
        attachmentScroll.alwaysBounceHorizontal = false
        attachmentStack.axis = .horizontal
        attachmentStack.alignment = .center
        attachmentStack.spacing = 8
        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        attachmentScroll.addSubview(attachmentStack)
        NSLayoutConstraint.activate([
            attachmentStack.leadingAnchor.constraint(equalTo: attachmentScroll.contentLayoutGuide.leadingAnchor),
            attachmentStack.trailingAnchor.constraint(equalTo: attachmentScroll.contentLayoutGuide.trailingAnchor),
            attachmentStack.topAnchor.constraint(equalTo: attachmentScroll.contentLayoutGuide.topAnchor, constant: 2),
            attachmentStack.bottomAnchor.constraint(equalTo: attachmentScroll.contentLayoutGuide.bottomAnchor, constant: -2),
            attachmentStack.heightAnchor.constraint(equalTo: attachmentScroll.frameLayoutGuide.heightAnchor, constant: -4),
            attachmentScroll.heightAnchor.constraint(equalToConstant: 64),
        ])
        attachmentScroll.isHidden = true
        rootStack.addArrangedSubview(attachmentScroll)

        configureIconButton(
            attachButton,
            symbol: "paperclip",
            identifier: "ChatComposerAttach",
            label: String(
                localized: "chat.composer.attach.accessibility",
                defaultValue: "Add attachment",
                bundle: .module
            ),
            selector: #selector(presentAttachmentPicker)
        )
        configureIconButton(
            micButton,
            symbol: "mic",
            identifier: "ChatComposerMic",
            label: L10n.string("mobile.composer.mic.start", defaultValue: "Start dictation"),
            selector: #selector(toggleDictation)
        )

        configureFieldBackground()
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityIdentifier = "ChatComposerField"
        textView.textContainerInset = UIEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.returnKeyType = .default
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 1
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 3),
        ])

        sendButton.accessibilityIdentifier = "ChatComposerSend"
        sendButton.addTarget(self, action: #selector(performPrimaryAction), for: .primaryActionTriggered)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sendButton.widthAnchor.constraint(equalToConstant: 28),
            sendButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        fieldContent.axis = .horizontal
        fieldContent.alignment = .bottom
        fieldContent.spacing = 8
        fieldContent.isLayoutMarginsRelativeArrangement = true
        fieldContent.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 6,
            leading: 14,
            bottom: 6,
            trailing: 6
        )
        fieldContent.addArrangedSubview(textView)
        fieldContent.addArrangedSubview(sendButton)
        fieldContent.translatesAutoresizingMaskIntoConstraints = false
        fieldBackground.contentView.addSubview(fieldContent)
        NSLayoutConstraint.activate([
            fieldContent.leadingAnchor.constraint(equalTo: fieldBackground.contentView.leadingAnchor),
            fieldContent.trailingAnchor.constraint(equalTo: fieldBackground.contentView.trailingAnchor),
            fieldContent.topAnchor.constraint(equalTo: fieldBackground.contentView.topAnchor),
            fieldContent.bottomAnchor.constraint(equalTo: fieldBackground.contentView.bottomAnchor),
            fieldBackground.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumFieldHeight),
        ])

        fieldRow.axis = .horizontal
        fieldRow.alignment = .bottom
        fieldRow.spacing = 8
        fieldRow.addArrangedSubview(attachButton)
        fieldRow.addArrangedSubview(micButton)
        fieldRow.addArrangedSubview(fieldBackground)
        rootStack.addArrangedSubview(fieldRow)

        let initialHeight = textView.heightAnchor.constraint(equalToConstant: 28)
        initialHeight.priority = .required
        initialHeight.isActive = true
        textHeightConstraint = initialHeight

        #if DEBUG
        let autofocus = ChatComposerDebugAutofocusView(frame: .zero)
        autofocus.translatesAutoresizingMaskIntoConstraints = false
        addSubview(autofocus)
        NSLayoutConstraint.activate([
            autofocus.leadingAnchor.constraint(equalTo: leadingAnchor),
            autofocus.topAnchor.constraint(equalTo: topAnchor),
            autofocus.widthAnchor.constraint(equalToConstant: 0),
            autofocus.heightAnchor.constraint(equalToConstant: 0),
        ])
        #endif
    }

    private func configureFieldBackground() {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            fieldBackground.effect = effect
        } else {
            fieldBackground.effect = UIBlurEffect(style: .systemThinMaterial)
            fieldBackground.layer.borderWidth = 1
            fieldBackground.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        }
        fieldBackground.clipsToBounds = true
        fieldBackground.layer.cornerRadius = 20
        fieldBackground.layer.cornerCurve = .continuous
    }

    private func configureIconButton(
        _ button: UIButton,
        symbol: String,
        identifier: String,
        label: String,
        selector: Selector
    ) {
        var buttonConfiguration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            buttonConfiguration = .glass()
        } else {
            buttonConfiguration = .gray()
        }
        buttonConfiguration.image = UIImage(systemName: symbol)
        buttonConfiguration.cornerStyle = .capsule
        button.configuration = buttonConfiguration
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        button.addTarget(self, action: selector, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func observeDictation() {
        withObservationTracking {
            _ = dictation.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateMicButton()
                self.observeDictation()
            }
        }
        updateMicButton()
    }

    private func updateMicButton() {
        let listening = dictation.state.isListening
        var buttonConfiguration = micButton.configuration
        buttonConfiguration?.image = UIImage(systemName: listening ? "mic.fill" : "mic")
        buttonConfiguration?.baseForegroundColor = listening ? .systemRed : .secondaryLabel
        micButton.configuration = buttonConfiguration
        micButton.isEnabled = dictation.isAvailable
        micButton.accessibilityLabel = listening
            ? L10n.string("mobile.composer.mic.stop", defaultValue: "Stop dictation")
            : L10n.string("mobile.composer.mic.start", defaultValue: "Start dictation")
        textView.isEditable = !dictation.locksComposerField
        if listening, micButton.layer.animation(forKey: "chat.dictation.pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.5
            pulse.duration = 0.75
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            micButton.layer.add(pulse, forKey: "chat.dictation.pulse")
        } else if !listening {
            micButton.layer.removeAnimation(forKey: "chat.dictation.pulse")
        }
    }

    private func updateSendButton() {
        let hasContent = !trimmedDraft.isEmpty || !attachments.isEmpty
        let isWorking: Bool = if case .working = configuration.agentState { true } else { false }
        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.cornerStyle = .capsule
        if hasContent {
            buttonConfiguration.image = UIImage(systemName: "arrow.up")
            buttonConfiguration.baseBackgroundColor = .systemBlue
            buttonConfiguration.baseForegroundColor = .white
            sendButton.isEnabled = configuration.isConnected && !isStagingAttachments
            sendButton.accessibilityLabel = String(
                localized: "chat.composer.send.accessibility",
                defaultValue: "Send",
                bundle: .module
            )
        } else if isWorking {
            buttonConfiguration.image = UIImage(systemName: "stop.fill")
            buttonConfiguration.baseBackgroundColor = .systemRed
            buttonConfiguration.baseForegroundColor = .white
            sendButton.isEnabled = true
            sendButton.accessibilityLabel = String(
                localized: "chat.composer.stop.accessibility",
                defaultValue: "Stop",
                bundle: .module
            )
        } else {
            buttonConfiguration.image = UIImage(systemName: "arrow.up")
            buttonConfiguration.baseBackgroundColor = .tertiarySystemFill
            buttonConfiguration.baseForegroundColor = .tertiaryLabel
            sendButton.isEnabled = false
            sendButton.accessibilityLabel = String(
                localized: "chat.composer.send.accessibility",
                defaultValue: "Send",
                bundle: .module
            )
        }
        sendButton.configuration = buttonConfiguration
    }

    private func updateTextHeight() {
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        let minimum = ceil(font.lineHeight + textView.textContainerInset.top + textView.textContainerInset.bottom)
        let maximum = ceil((font.lineHeight * 6) + textView.textContainerInset.top + textView.textContainerInset.bottom)
        let fitting = textView.sizeThatFits(CGSize(width: max(textView.bounds.width, 160), height: .greatestFiniteMagnitude))
        let height = min(max(minimum, ceil(fitting.height)), maximum)
        textView.isScrollEnabled = fitting.height > maximum + 0.5
        guard abs((textHeightConstraint?.constant ?? 0) - height) > 0.5 else { return }
        textHeightConstraint?.constant = height
        invalidateComposerHeight()
    }

    private func invalidateComposerHeight() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        onIntrinsicHeightChanged()
    }

    private func rebuildAttachmentStrip() {
        for view in attachmentStack.arrangedSubviews {
            attachmentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, attachment) in attachments.enumerated() {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: 60),
                container.heightAnchor.constraint(equalToConstant: 60),
            ])

            let image = UIImageView(image: attachment.thumbnail)
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            image.layer.cornerRadius = 10
            image.layer.cornerCurve = .continuous
            image.isAccessibilityElement = true
            image.accessibilityLabel = String(
                localized: "chat.composer.attachment.accessibility",
                defaultValue: "Attachment \(index + 1)",
                bundle: .module
            )
            image.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(image)

            let remove = UIButton(type: .system)
            var removeConfiguration = UIButton.Configuration.plain()
            removeConfiguration.image = UIImage(systemName: "xmark.circle.fill")
            removeConfiguration.baseForegroundColor = .white
            removeConfiguration.contentInsets = .zero
            remove.configuration = removeConfiguration
            remove.accessibilityLabel = String(
                localized: "chat.composer.remove_attachment.accessibility",
                defaultValue: "Remove attachment \(index + 1)",
                bundle: .module
            )
            remove.addAction(UIAction { [weak self] _ in
                self?.removeAttachment(id: attachment.id)
            }, for: .primaryActionTriggered)
            remove.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(remove)

            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                image.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                image.topAnchor.constraint(equalTo: container.topAnchor),
                image.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                remove.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 7),
                remove.topAnchor.constraint(equalTo: container.topAnchor, constant: -7),
                remove.widthAnchor.constraint(equalToConstant: 44),
                remove.heightAnchor.constraint(equalToConstant: 44),
            ])
            container.isAccessibilityElement = false
            attachmentStack.addArrangedSubview(container)
        }
        attachmentScroll.isHidden = attachments.isEmpty
    }

    private func remapped(_ shortcuts: [ChatAccessoryShortcut]) -> [ChatAccessoryShortcut] {
        shortcuts.map { shortcut in
            switch shortcut.semanticAction {
            case .dismissKeyboard:
                shortcut.replacingAction { [weak self] in self?.dismissKeyboard() }
            case .paste:
                shortcut.replacingAction { [weak self] in self?.performPaste() }
            case nil:
                shortcut
            }
        }
    }

    private var placeholder: String {
        if configuration.isTerminal {
            return String(
                localized: "chat.composer.placeholder.terminal",
                defaultValue: "❯ command",
                bundle: .module
            )
        }
        return String(
            localized: "chat.composer.placeholder",
            defaultValue: "Message \(configuration.agentKind.displayName)",
            bundle: .module
        )
    }

    private var trimmedDraft: String {
        textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func presentAttachmentPicker() {
        var pickerConfiguration = PHPickerConfiguration(photoLibrary: .shared())
        pickerConfiguration.filter = .images
        pickerConfiguration.selectionLimit = 4
        pickerConfiguration.selection = .ordered
        let picker = PHPickerViewController(configuration: pickerConfiguration)
        picker.delegate = self
        nearestViewController?.present(picker, animated: true)
    }

    @objc private func toggleDictation() {
        dictation.toggle(existingText: textView.text) { [weak self] merged in
            guard let self else { return }
            self.textView.text = merged
            self.configuration.setDraft(merged)
            self.placeholderLabel.isHidden = !merged.isEmpty
            self.updateTextHeight()
            self.updateSendButton()
        }
    }

    @objc private func performPrimaryAction() {
        let hasContent = !trimmedDraft.isEmpty || !attachments.isEmpty
        if hasContent {
            performSend()
        } else if case .working = configuration.agentState {
            performStop()
        }
    }

    private func performSend() {
        guard (!trimmedDraft.isEmpty || !attachments.isEmpty),
              !isStagingAttachments else { return }
        dictation.cancel()
        let outbound = attachments.map(\.outbound)
        MobileHapticFeedback().impact(style: .light)
        configuration.onSend(trimmedDraft, outbound)
        textView.text = ""
        configuration.setDraft("")
        attachments = []
        rebuildAttachmentStrip()
        placeholderLabel.isHidden = false
        updateTextHeight()
        updateSendButton()
    }

    private func performStop() {
        MobileHapticFeedback().impact(style: .rigid)
        let now = Date()
        configuration.onInterrupt(
            lastStopTap.map { now.timeIntervalSince($0) < Self.hardStopWindow } ?? false
        )
        lastStopTap = now
    }

    private func dismissKeyboard() {
        textView.resignFirstResponder()
    }

    private func performPaste() {
        let pasteboard = UIPasteboard.general
        if attachments.count < 4,
           let attachment = pasteboard.chatComposerAttachment(
               maxDimension: Self.maxAttachmentDimension,
               jpegQuality: Self.jpegQuality
           ) {
            attachments.append(attachment)
            rebuildAttachmentStrip()
            updateSendButton()
            invalidateComposerHeight()
            _ = textView.becomeFirstResponder()
            return
        }
        guard let string = pasteboard.chatComposerText() else { return }
        textView.text += string
        configuration.setDraft(textView.text)
        placeholderLabel.isHidden = true
        updateTextHeight()
        updateSendButton()
        _ = textView.becomeFirstResponder()
    }

    private func removeAttachment(id: String) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments.remove(at: index)
        rebuildAttachmentStrip()
        updateSendButton()
        invalidateComposerHeight()
    }
}

private extension UIView {
    var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

private extension NSItemProvider {
    @MainActor
    func chatComposerImageData() async -> Data? {
        await withCheckedContinuation { continuation in
            loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
#endif
