#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import ImageIO
import Observation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Native controller for the terminal's surface-owned composer band.
@MainActor
final class TerminalComposerViewController: UIViewController {
    private let composerView: TerminalComposerNativeView

    init(
        store: CMUXMobileShellStore,
        terminalID: String,
        requestHeightRemeasure: @escaping @MainActor () -> Void,
        prepareForModalPresentation: @escaping @MainActor () -> Void
    ) {
        composerView = TerminalComposerNativeView(
            store: store,
            terminalID: terminalID,
            requestHeightRemeasure: requestHeightRemeasure,
            prepareForModalPresentation: prepareForModalPresentation
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = composerView
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        composerView.bounds.size.width = width
        composerView.setNeedsLayout()
        composerView.layoutIfNeeded()
        return ceil(composerView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
    }

    func prepareForDismantle() {
        composerView.prepareForDismantle()
    }
}

/// iMessage-style UIKit composer with bounded image staging and structured task ownership.
@MainActor
final class TerminalComposerNativeView: UIView, UITextViewDelegate, PHPickerViewControllerDelegate {
    private static let controlHeight: CGFloat = 40
    private static let inlineSendDiameter: CGFloat = 28
    private static let minimumFieldHeight: CGFloat = 40
    private static let maximumLineCount: CGFloat = 14
    private nonisolated static let maxImageBytes = CMUXMobileShellStore.maxPendingAttachmentImageBytes
    private static let maxAttachmentCount = CMUXMobileShellStore.maxPendingAttachmentCount
    private static let maxTotalAttachmentBytes = CMUXMobileShellStore.maxPendingAttachmentTotalBytes
    private static let maxRawInputBytes = 60 * 1024 * 1024
    private nonisolated static let thumbnailMaxPixelSize = 168
    private nonisolated static let sendMaxPixelSize = 2_048

    private let store: CMUXMobileShellStore
    private let terminalID: String
    private let requestHeightRemeasure: @MainActor () -> Void
    private let prepareForModalPresentation: @MainActor () -> Void
    private let dictation = ComposerDictationController()

    private let rootStack = UIStackView()
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

    private var stagingTask: Task<Void, Never>?
    private var submitTask: Task<Void, Never>?
    private var thumbnailCache: [UUID: UIImage] = [:]
    private var renderedAttachmentIDs: [UUID] = []
    private var lastMeasuredWidth: CGFloat = 0
    private var isMounted = false

    init(
        store: CMUXMobileShellStore,
        terminalID: String,
        requestHeightRemeasure: @escaping @MainActor () -> Void,
        prepareForModalPresentation: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.terminalID = terminalID
        self.requestHeightRemeasure = requestHeightRemeasure
        self.prepareForModalPresentation = prepareForModalPresentation
        super.init(frame: .zero)
        configureViews()
        observeStore()
        observeDictation()
        refreshFromStore()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            guard isMounted else { return }
            isMounted = false
            recordComposerEvent(.composerViewDisappear)
            stagingTask?.cancel()
            stagingTask = nil
            dictation.cancel()
            store.composerFieldFocusChanged(false)
            return
        }

        guard !isMounted else { return }
        isMounted = true
        recordComposerEvent(.composerViewAppear)
        refreshFromStore()
        consumePendingFocusRequest()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0, abs(width - lastMeasuredWidth) > 0.5 else { return }
        lastMeasuredWidth = width
        updateTextHeight(notify: false)
    }

    func prepareForDismantle() {
        stagingTask?.cancel()
        stagingTask = nil
        submitTask?.cancel()
        submitTask = nil
        dictation.cancel()
        endEditing(true)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        store.composerFieldFocusChanged(true)
        recordComposerEvent(.composerFieldFocusChanged, a: 1)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        store.composerFieldFocusChanged(false)
        if !dictation.locksComposerField {
            dictation.stop()
        }
        recordComposerEvent(.composerFieldFocusChanged, a: 0)
    }

    func textViewDidChange(_ textView: UITextView) {
        store.terminalInputText = textView.text
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateTextHeight(notify: true)
        updateSendButton()
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        stagePickedResults(results)
    }

    private func configureViews() {
        backgroundColor = .clear
        accessibilityIdentifier = "MobileTerminalComposer"
        accessibilityContainerType = .semanticGroup

        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 6
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

        attachmentScroll.showsHorizontalScrollIndicator = false
        attachmentScroll.isDirectionalLockEnabled = true
        attachmentScroll.alwaysBounceHorizontal = false
        attachmentScroll.contentInset.left = Self.controlHeight + 8
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
            identifier: "MobileComposerAttach",
            label: L10n.string("mobile.composer.attach", defaultValue: "Attach Photo"),
            selector: #selector(presentPhotoPicker)
        )
        configureIconButton(
            micButton,
            symbol: "mic",
            identifier: "MobileComposerMic",
            label: L10n.string("mobile.composer.mic.start", defaultValue: "Start dictation"),
            selector: #selector(toggleDictation)
        )

        configureFieldBackground()
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.isScrollEnabled = false
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .yes
        textView.spellCheckingType = .yes
        textView.adjustsFontForContentSizeCategory = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = UIEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityIdentifier = "MobileComposerField"
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        placeholderLabel.text = L10n.string("mobile.composer.placeholder", defaultValue: "Message")
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = textView.font
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 3),
        ])

        sendButton.accessibilityIdentifier = "MobileComposerSend"
        sendButton.accessibilityLabel = L10n.string("mobile.composer.send", defaultValue: "Send")
        sendButton.addTarget(self, action: #selector(send), for: .primaryActionTriggered)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sendButton.widthAnchor.constraint(equalToConstant: Self.inlineSendDiameter),
            sendButton.heightAnchor.constraint(equalToConstant: Self.inlineSendDiameter),
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
        initialHeight.isActive = true
        textHeightConstraint = initialHeight
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
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = .glass()
        } else {
            configuration = .gray()
        }
        configuration.image = UIImage(systemName: symbol)
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = label
        button.addTarget(self, action: selector, for: .primaryActionTriggered)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.controlHeight),
            button.heightAnchor.constraint(equalToConstant: Self.controlHeight),
        ])
    }

    private func observeStore() {
        withObservationTracking {
            _ = store.terminalInputText
            _ = store.composerFocusRequest
            _ = store.activeTerminalTheme
            _ = store.pendingAttachments(forTerminalID: terminalID)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeStore()
                self.refreshFromStore()
            }
        }
    }

    private func observeDictation() {
        withObservationTracking {
            _ = dictation.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeDictation()
                self.updateMicButton()
            }
        }
        updateMicButton()
    }

    private func refreshFromStore() {
        let draft = store.terminalInputText
        if textView.text != draft {
            textView.text = draft
            updateTextHeight(notify: true)
        }
        placeholderLabel.isHidden = !draft.isEmpty

        let attachments = pendingAttachments
        let ids = attachments.map(\.id)
        if ids != renderedAttachmentIDs {
            renderedAttachmentIDs = ids
            rebuildAttachmentStrip(attachments)
            requestHeightRemeasure()
        }

        applyTheme(store.activeTerminalTheme)
        updateSendButton()
        consumePendingFocusRequest()
    }

    private func applyTheme(_ theme: TerminalTheme) {
        textView.textColor = theme.terminalForegroundUIColor
        let chromeColor = readableChromeColor(for: theme)
        var attachConfiguration = attachButton.configuration
        attachConfiguration?.baseForegroundColor = chromeColor.withAlphaComponent(0.78)
        attachButton.configuration = attachConfiguration
        updateMicButton()
        overrideUserInterfaceStyle = prefersDarkInterface(for: theme) ? .dark : .light
    }

    private func updateTextHeight(notify: Bool) {
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        let verticalInsets = textView.textContainerInset.top + textView.textContainerInset.bottom
        let minimum = ceil(font.lineHeight + verticalInsets)
        let maximum = ceil((font.lineHeight * Self.maximumLineCount) + verticalInsets)
        let availableWidth = max(textView.bounds.width, bounds.width - 140, 160)
        let fitting = textView.sizeThatFits(
            CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        )
        let height = min(max(minimum, ceil(fitting.height)), maximum)
        textView.isScrollEnabled = fitting.height > maximum + 0.5
        guard abs((textHeightConstraint?.constant ?? 0) - height) > 0.5 else { return }
        textHeightConstraint?.constant = height
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        if notify {
            requestHeightRemeasure()
        }
    }

    private func updateMicButton() {
        let listening = dictation.state.isListening
        var configuration = micButton.configuration
        configuration?.image = UIImage(systemName: listening ? "mic.fill" : "mic")
        configuration?.baseForegroundColor = listening
            ? .systemRed
            : readableChromeColor(for: store.activeTerminalTheme).withAlphaComponent(0.78)
        micButton.configuration = configuration
        micButton.isEnabled = dictation.isAvailable
        micButton.accessibilityLabel = listening
            ? L10n.string("mobile.composer.mic.stop", defaultValue: "Stop dictation")
            : L10n.string("mobile.composer.mic.start", defaultValue: "Start dictation")
        textView.isEditable = !dictation.locksComposerField
        if listening, micButton.layer.animation(forKey: "terminal.dictation.pulse") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.5
            pulse.duration = 0.75
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            micButton.layer.add(pulse, forKey: "terminal.dictation.pulse")
        } else if !listening {
            micButton.layer.removeAnimation(forKey: "terminal.dictation.pulse")
        }
    }

    private func updateSendButton() {
        let enabled = store.composerCanSend(forTerminalID: terminalID) && submitTask == nil
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "arrow.up")
        configuration.baseForegroundColor = enabled
            ? .white
            : store.activeTerminalTheme.terminalForegroundUIColor.withAlphaComponent(0.35)
        configuration.baseBackgroundColor = enabled
            ? .systemBlue
            : store.activeTerminalTheme.terminalForegroundUIColor.withAlphaComponent(0.12)
        configuration.contentInsets = .zero
        sendButton.configuration = configuration
        sendButton.isEnabled = enabled
    }

    private func rebuildAttachmentStrip(_ attachments: [MobilePendingAttachment]) {
        for view in attachmentStack.arrangedSubviews {
            attachmentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for attachment in attachments {
            attachmentStack.addArrangedSubview(makeAttachmentChip(attachment))
        }
        attachmentScroll.isHidden = attachments.isEmpty
    }

    private func makeAttachmentChip(_ attachment: MobilePendingAttachment) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 60),
            container.heightAnchor.constraint(equalToConstant: 60),
        ])

        let imageView = UIImageView(image: thumbnailCache[attachment.id])
        imageView.backgroundColor = store.activeTerminalTheme.terminalForegroundUIColor.withAlphaComponent(0.12)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 10
        imageView.layer.cornerCurve = .continuous
        imageView.layer.borderWidth = 1
        imageView.layer.borderColor = store.activeTerminalTheme.terminalForegroundUIColor
            .withAlphaComponent(0.15).cgColor
        imageView.accessibilityIdentifier = "MobileComposerAttachment"
        imageView.accessibilityLabel = L10n.string(
            "mobile.composer.attachment",
            defaultValue: "Photo Attachment"
        )
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)

        let remove = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark.circle.fill")
        configuration.baseForegroundColor = .white
        configuration.contentInsets = .zero
        remove.configuration = configuration
        remove.accessibilityIdentifier = "MobileComposerAttachmentRemove"
        remove.accessibilityLabel = L10n.string(
            "mobile.composer.attachment.remove",
            defaultValue: "Remove Attachment"
        )
        remove.addAction(UIAction { [weak self] _ in
            self?.removeAttachment(id: attachment.id)
        }, for: .primaryActionTriggered)
        remove.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(remove)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            remove.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 7),
            remove.topAnchor.constraint(equalTo: container.topAnchor, constant: -7),
            remove.widthAnchor.constraint(equalToConstant: 44),
            remove.heightAnchor.constraint(equalToConstant: 44),
        ])
        return container
    }

    private func consumePendingFocusRequest() {
        guard isMounted,
              store.consumePendingComposerFocusRequest(for: terminalID) else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            _ = self?.textView.becomeFirstResponder()
        }
    }

    @objc private func presentPhotoPicker() {
        endEditing(true)
        prepareForModalPresentation()
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = Self.maxAttachmentCount
        configuration.selection = .ordered
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        nearestViewController?.present(picker, animated: true)
    }

    @objc private func toggleDictation() {
        dictation.toggle(existingText: textView.text) { [weak self] merged in
            guard let self else { return }
            self.textView.text = merged
            self.store.terminalInputText = merged
            self.placeholderLabel.isHidden = !merged.isEmpty
            self.updateTextHeight(notify: true)
            self.updateSendButton()
        }
    }

    @objc private func send() {
        guard store.composerCanSend(forTerminalID: terminalID), submitTask == nil else { return }
        dictation.cancel()
        _ = textView.becomeFirstResponder()
        submitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.updateSendButton()
            await self.store.submitComposer()
            guard !Task.isCancelled else { return }
            let keep = Set(self.pendingAttachments.map(\.id))
            self.thumbnailCache = self.thumbnailCache.filter { keep.contains($0.key) }
            self.submitTask = nil
            self.refreshFromStore()
            self.requestHeightRemeasure()
        }
    }

    private func removeAttachment(id: UUID) {
        store.removePendingAttachment(id: id, forTerminalID: terminalID)
        thumbnailCache[id] = nil
        refreshFromStore()
    }

    private func stagePickedResults(_ results: [PHPickerResult]) {
        let sessionGeneration = store.currentSessionGeneration
        stagingTask?.cancel()
        stagingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for result in results {
                guard !Task.isCancelled else { break }
                let staged = self.pendingAttachments
                guard staged.count < Self.maxAttachmentCount else { break }
                let stagedBytes = staged.reduce(0) { $0 + $1.data.count }
                guard stagedBytes < Self.maxTotalAttachmentBytes else { break }

                guard let imported = try? await result.itemProvider.importedImageFile() else { continue }
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: imported.url)
                    break
                }
                defer { try? FileManager.default.removeItem(at: imported.url) }

                if let value = try? imported.url.resourceValues(forKeys: [.fileSizeKey]),
                   let size = value.fileSize,
                   size > Self.maxRawInputBytes {
                    continue
                }
                guard let prepared = await Self.prepare(url: imported.url), !Task.isCancelled else { continue }
                guard let id = self.store.addPendingAttachment(
                    prepared.data,
                    format: prepared.format,
                    forTerminalID: self.terminalID,
                    ifSessionGeneration: sessionGeneration
                ) else { continue }
                if let data = prepared.thumbnail, let image = UIImage(data: data) {
                    self.thumbnailCache[id] = image
                }
            }
            guard !Task.isCancelled else { return }
            self.stagingTask = nil
            self.refreshFromStore()
            self.requestHeightRemeasure()
        }
    }

    private var pendingAttachments: [MobilePendingAttachment] {
        store.pendingAttachments(forTerminalID: terminalID)
    }

    private func readableChromeColor(for theme: TerminalTheme) -> UIColor {
        prefersDarkInterface(for: theme) ? .white : .black
    }

    private func prefersDarkInterface(for theme: TerminalTheme) -> Bool {
        guard let rgb = TerminalTheme.rgbComponents(theme.background) else { return true }
        let channels = [rgb.red, rgb.green, rgb.blue].map { component -> Double in
            let value = Double(component) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        let whiteContrast = 1.05 / (luminance + 0.05)
        let blackContrast = (luminance + 0.05) / 0.05
        return whiteContrast >= blackContrast
    }

    private func recordComposerEvent(_ code: DiagnosticEventCode, a: Int? = nil) {
        #if DEBUG
        store.diagnosticLog?.record(DiagnosticEvent(code, a: a))
        #endif
    }

    private struct PreparedAttachment: Sendable {
        var data: Data
        var format: String
        var thumbnail: Data?
    }

    private nonisolated static func prepare(url: URL) async -> PreparedAttachment? {
        guard !Task.isCancelled else { return nil }
        return await withTaskGroup(of: PreparedAttachment?.self) { group in
            group.addTask(priority: .background) {
                guard !Task.isCancelled,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let (data, format) = boundedSendPayload(from: source),
                      !Task.isCancelled else { return nil }
                return PreparedAttachment(
                    data: data,
                    format: format,
                    thumbnail: downsampledImageData(
                        from: source,
                        maxPixelSize: thumbnailMaxPixelSize,
                        type: "public.png",
                        jpegQuality: nil
                    )
                )
            }
            return await group.next() ?? nil
        }
    }

    private nonisolated static func boundedSendPayload(
        from source: CGImageSource
    ) -> (data: Data, format: String)? {
        if let png = downsampledImageData(
            from: source,
            maxPixelSize: sendMaxPixelSize,
            type: "public.png",
            jpegQuality: nil
        ), png.count <= maxImageBytes {
            return (png, "png")
        }
        for quality in [0.8, 0.6, 0.4] as [CGFloat] {
            if let jpeg = downsampledImageData(
                from: source,
                maxPixelSize: sendMaxPixelSize,
                type: "public.jpeg",
                jpegQuality: quality
            ), jpeg.count <= maxImageBytes {
                return (jpeg, "jpg")
            }
        }
        for maxPixel in [1_536, 1_024, 768] {
            if let jpeg = downsampledImageData(
                from: source,
                maxPixelSize: maxPixel,
                type: "public.jpeg",
                jpegQuality: 0.5
            ), jpeg.count <= maxImageBytes {
                return (jpeg, "jpg")
            }
        }
        guard let jpeg = downsampledImageData(
            from: source,
            maxPixelSize: 768,
            type: "public.jpeg",
            jpegQuality: 0.4
        ) else { return nil }
        return (jpeg, "jpg")
    }

    private nonisolated static func downsampledImageData(
        from source: CGImageSource,
        maxPixelSize: Int,
        type: String,
        jpegQuality: CGFloat?
    ) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData,
            type as CFString,
            1,
            nil
        ) else { return nil }
        var properties: [CFString: Any] = [:]
        if let jpegQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}

private struct ImportedImageFile: Sendable {
    let url: URL
}

private enum ImportedImageFileError: Error {
    case unavailable
}

private extension NSItemProvider {
    @MainActor
    func importedImageFile() async throws -> ImportedImageFile {
        try await withCheckedThrowingContinuation { continuation in
            loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { source, error in
                guard let source else {
                    continuation.resume(throwing: error ?? ImportedImageFileError.unavailable)
                    return
                }
                do {
                    let suffix = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
                    let destination = FileManager.default.temporaryDirectory
                        .appendingPathComponent("cmux-composer-import-\(UUID().uuidString)\(suffix)")
                    try FileManager.default.copyItem(at: source, to: destination)
                    continuation.resume(returning: ImportedImageFile(url: destination))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
#endif
