import CmuxFoundation
import AppKit

@MainActor
final class KeyboardShortcutRecorderNativeView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let recorderButton = ShortcutRecorderNSButton()
    private let clearRestoreButton = NSButton()
    private let validationContainer = NSView()
    private let validationMessageField = NSTextField(wrappingLabelWithString: "")
    private let validationButton = NSButton()
    private let undoButton = NSButton()
    private var shortcut = StoredShortcut.unbound
    private var restoreShortcut: StoredShortcut?
    private var onShortcutChanged: (StoredShortcut) -> Void = { _ in }
    private var onValidationButtonPressed: (() -> Void)?
    private var onUndoButtonPressed: (() -> Void)?
    private var onRecorderFeedbackChanged: (ShortcutRecorderRejectedAttempt?) -> Void = { _ in }
    private var isDisabled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        label: String,
        subtitle: String?,
        shortcut: StoredShortcut,
        displayString: @escaping (StoredShortcut) -> String,
        transformRecordedShortcut: @escaping (StoredShortcut) -> KeyboardShortcutSettings.RecordedShortcutResolution,
        validationMessage: String?,
        validationButtonTitle: String?,
        onValidationButtonPressed: (() -> Void)?,
        undoButtonTitle: String?,
        onUndoButtonPressed: (() -> Void)?,
        hasPendingRejection: Bool,
        isDisabled: Bool,
        firstStrokeRequiresModifier: Bool,
        onShortcutChanged: @escaping (StoredShortcut) -> Void,
        onRecordingChanged: @escaping (Bool) -> Void,
        onRecorderFeedbackChanged: @escaping (ShortcutRecorderRejectedAttempt?) -> Void
    ) {
        if self.shortcut != shortcut, !shortcut.isUnbound {
            restoreShortcut = nil
        }
        self.shortcut = shortcut
        self.isDisabled = isDisabled
        self.onShortcutChanged = onShortcutChanged
        self.onValidationButtonPressed = onValidationButtonPressed
        self.onUndoButtonPressed = onUndoButtonPressed
        self.onRecorderFeedbackChanged = onRecorderFeedbackChanged

        titleField.stringValue = label
        subtitleField.stringValue = subtitle ?? ""
        subtitleField.isHidden = subtitle == nil
        recorderButton.shortcut = shortcut
        recorderButton.displayString = displayString
        recorderButton.transformRecordedShortcut = transformRecordedShortcut
        recorderButton.firstStrokeRequiresModifier = firstStrokeRequiresModifier
        recorderButton.isEnabled = !isDisabled
        recorderButton.onShortcutRecorded = { [weak self] newShortcut in
            guard let self else { return }
            self.shortcut = newShortcut
            self.restoreShortcut = nil
            self.onShortcutChanged(newShortcut)
            self.onRecorderFeedbackChanged(nil)
            self.updateClearRestoreButton()
        }
        recorderButton.onRecordingChanged = onRecordingChanged
        recorderButton.onRecorderFeedbackChanged = onRecorderFeedbackChanged
        if !hasPendingRejection {
            recorderButton.clearPendingRejection()
        }
        recorderButton.updateTitle()

        validationMessageField.stringValue = validationMessage ?? ""
        validationContainer.isHidden = validationMessage == nil
        configureActionButton(validationButton, title: validationButtonTitle, action: onValidationButtonPressed)
        configureActionButton(undoButton, title: undoButtonTitle, action: onUndoButtonPressed)
        updateClearRestoreButton()
        invalidateIntrinsicContentSize()
    }

    private func configureViews() {
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.maximumNumberOfLines = 2

        let labelStack = NSStackView(views: [titleField, subtitleField])
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2

        recorderButton.translatesAutoresizingMaskIntoConstraints = false
        recorderButton.widthAnchor.constraint(equalToConstant: 160).isActive = true

        clearRestoreButton.isBordered = false
        clearRestoreButton.imagePosition = .imageOnly
        clearRestoreButton.target = self
        clearRestoreButton.action = #selector(clearOrRestore(_:))
        clearRestoreButton.setAccessibilityIdentifier("ShortcutRecorderClearRestoreButton")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let topRow = NSStackView(views: [labelStack, spacer, recorderButton, clearRestoreButton])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 12

        validationContainer.wantsLayer = true
        validationContainer.layer?.cornerRadius = 6
        validationContainer.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12).cgColor
        validationContainer.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.35).cgColor
        validationContainer.layer?.borderWidth = 1
        validationContainer.setAccessibilityIdentifier("ShortcutRecorderValidationMessage")

        let warningImage = NSImageView(image: NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        ) ?? NSImage())
        warningImage.contentTintColor = .systemRed
        warningImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        validationMessageField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationMessageField.textColor = .systemRed
        validationMessageField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let validationRow = NSStackView(views: [warningImage, validationMessageField, validationButton, undoButton])
        validationRow.orientation = .horizontal
        validationRow.alignment = .firstBaseline
        validationRow.spacing = 8
        validationRow.translatesAutoresizingMaskIntoConstraints = false
        validationContainer.addSubview(validationRow)
        NSLayoutConstraint.activate([
            validationRow.leadingAnchor.constraint(equalTo: validationContainer.leadingAnchor, constant: 8),
            validationRow.trailingAnchor.constraint(lessThanOrEqualTo: validationContainer.trailingAnchor, constant: -8),
            validationRow.topAnchor.constraint(equalTo: validationContainer.topAnchor, constant: 6),
            validationRow.bottomAnchor.constraint(equalTo: validationContainer.bottomAnchor, constant: -6),
        ])

        let rootStack = NSStackView(views: [topRow, validationContainer])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 4
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            validationContainer.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
        ])
    }

    private func configureActionButton(
        _ button: NSButton,
        title: String?,
        action: (() -> Void)?
    ) {
        button.title = title ?? ""
        button.isHidden = title == nil || action == nil
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.target = self
        button.action = button === validationButton
            ? #selector(validationAction(_:))
            : #selector(undoAction(_:))
    }

    private func updateClearRestoreButton() {
        let canRestore = shortcut.isUnbound && restoreShortcut != nil
        let symbol = canRestore ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill"
        let help = canRestore
            ? String(localized: "shortcut.recorder.restore.help", defaultValue: "Restore previous shortcut")
            : String(localized: "shortcut.recorder.clear.help", defaultValue: "Unbind shortcut")
        clearRestoreButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        clearRestoreButton.toolTip = help
        clearRestoreButton.isEnabled = !isDisabled && (!shortcut.isUnbound || restoreShortcut != nil)
    }

    @objc private func clearOrRestore(_ sender: NSButton) {
        KeyboardShortcutRecorderActivity.stopAllRecording()
        let next: StoredShortcut
        if shortcut.isUnbound, let restoreShortcut {
            next = restoreShortcut
            self.restoreShortcut = nil
        } else if !shortcut.isUnbound {
            restoreShortcut = shortcut
            next = .unbound
        } else {
            return
        }
        shortcut = next
        recorderButton.shortcut = next
        recorderButton.updateTitle()
        onShortcutChanged(next)
        onRecorderFeedbackChanged(nil)
        updateClearRestoreButton()
    }

    @objc private func validationAction(_ sender: NSButton) {
        onValidationButtonPressed?()
    }

    @objc private func undoAction(_ sender: NSButton) {
        onUndoButtonPressed?()
    }
}

final class ShortcutRecorderNSButton: NSButton {
    private static weak var activeRecorder: ShortcutRecorderNSButton?

    var shortcut: StoredShortcut = KeyboardShortcutSettings.showNotificationsDefault {
        didSet {
            if shortcut != oldValue {
                hasPendingRejection = false
            }
        }
    }
    var displayString: (StoredShortcut) -> String = { $0.displayString }
    var transformRecordedShortcut: (StoredShortcut) -> KeyboardShortcutSettings.RecordedShortcutResolution = {
        .accepted($0)
    }
    var firstStrokeRequiresModifier = true
    var onShortcutRecorded: ((StoredShortcut) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onRecorderFeedbackChanged: ((ShortcutRecorderRejectedAttempt?) -> Void)?
    private var isRecording = false
    private var hasPendingRejection = false
    private var eventMonitor: Any?
    private var pendingChordStart: ShortcutStroke?
    private var hasRegisteredRecordingActivity = false
    private weak var previousFirstResponder: NSResponder?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else {
            return super.performKeyEquivalent(with: event)
        }
        return handleRecordingEvent(event) == nil
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        _ = handleRecordingEvent(event)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(buttonClicked)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stopRecordingFromNotification),
            name: KeyboardShortcutRecorderActivity.stopAllNotification,
            object: nil
        )
        updateTitle()
    }

    func updateTitle() {
        if isRecording {
            if let pendingChordStart {
                let format = String(localized: "shortcut.recorder.pendingChord", defaultValue: "%@ …")
                title = String.localizedStringWithFormat(format, pendingChordStart.displayString)
            } else {
                title = String(localized: "shortcut.pressShortcut.prompt", defaultValue: "Press shortcut…")
            }
        } else if hasPendingRejection {
            title = String(localized: "shortcut.pressShortcut.prompt", defaultValue: "Press shortcut…")
        } else {
            title = displayString(shortcut)
        }
    }

    @objc private func buttonClicked() {
        if isRecording {
            if let pendingChordStart {
                let storedShortcut = StoredShortcut(first: pendingChordStart)
                switch transformRecordedShortcut(storedShortcut) {
                case let .accepted(transformedShortcut):
                    shortcut = transformedShortcut
                    onShortcutRecorded?(transformedShortcut)
                    onRecorderFeedbackChanged?(nil)
                case let .rejected(reason):
                    hasPendingRejection = true
                    onRecorderFeedbackChanged?(
                        ShortcutRecorderRejectedAttempt(reason: reason, proposedShortcut: storedShortcut)
                    )
                    stopRecording()
                    return
                }
            }
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        KeyboardShortcutRecorderActivity.stopAllRecording()
        isRecording = true
        hasPendingRejection = false
        pendingChordStart = nil
        Self.activeRecorder = self
        previousFirstResponder = window?.firstResponder
        window?.makeFirstResponder(self)
        registerRecordingActivityIfNeeded()
        onRecordingChanged?(true)
        onRecorderFeedbackChanged?(nil)
        updateTitle()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            guard let self else { return event }
            return self.handleMonitoredRecordingEvent(event)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowResigned),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    private func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        if ShortcutStroke.isEscapeCancelEvent(event) {
            stopRecording()
            return nil
        }

        if pendingChordStart == nil {
            switch ShortcutStroke.recordingResult(from: event, requireModifier: firstStrokeRequiresModifier) {
            case let .accepted(firstStroke):
                let firstShortcut = StoredShortcut(first: firstStroke)
                switch transformRecordedShortcut(firstShortcut) {
                case let .accepted(transformedShortcut):
                    shortcut = transformedShortcut
                    onShortcutRecorded?(transformedShortcut)
                    onRecorderFeedbackChanged?(nil)
                    stopRecording()
                    return nil
                case let .rejected(reason):
                    hasPendingRejection = true
                    onRecorderFeedbackChanged?(
                        ShortcutRecorderRejectedAttempt(reason: reason, proposedShortcut: firstShortcut)
                    )
                    return nil
                }
            case let .rejected(reason):
                hasPendingRejection = true
                onRecorderFeedbackChanged?(
                    ShortcutRecorderRejectedAttempt(reason: reason, proposedShortcut: nil)
                )
                return nil
            case .unsupportedKey:
                return nil
            }
        }

        guard let pendingChordStart else {
            return nil
        }

        if let secondStroke = ShortcutStroke.from(event: event, requireModifier: false) {
            let newShortcut = StoredShortcut(first: pendingChordStart, second: secondStroke)
            switch transformRecordedShortcut(newShortcut) {
            case let .accepted(transformedShortcut):
                shortcut = transformedShortcut
                onShortcutRecorded?(transformedShortcut)
                onRecorderFeedbackChanged?(nil)
                stopRecording()
                return nil
            case let .rejected(reason):
                hasPendingRejection = true
                onRecorderFeedbackChanged?(
                    ShortcutRecorderRejectedAttempt(reason: reason, proposedShortcut: newShortcut)
                )
                return nil
            }
        }

        // Consume unsupported keys while recording to avoid triggering app shortcuts.
        return nil
    }

    private func handleMonitoredRecordingEvent(_ event: NSEvent) -> NSEvent? {
        handleRecordingEvent(event)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        pendingChordStart = nil
        if Self.activeRecorder === self {
            Self.activeRecorder = nil
        }
        unregisterRecordingActivityIfNeeded()
        onRecordingChanged?(false)
        updateTitle()

        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)

        if window?.firstResponder === self {
            window?.makeFirstResponder(previousFirstResponder)
        }
        previousFirstResponder = nil
    }

    @objc private func windowResigned() {
        stopRecording()
    }

    @objc private func stopRecordingFromNotification() {
        stopRecording()
    }

    func clearPendingRejection() {
        guard hasPendingRejection else { return }
        hasPendingRejection = false
        updateTitle()
    }

    private func registerRecordingActivityIfNeeded() {
        guard !hasRegisteredRecordingActivity else { return }
        hasRegisteredRecordingActivity = true
        KeyboardShortcutRecorderActivity.beginRecording()
    }

    private func unregisterRecordingActivityIfNeeded() {
        guard hasRegisteredRecordingActivity else { return }
        hasRegisteredRecordingActivity = false
        KeyboardShortcutRecorderActivity.endRecording()
    }

    fileprivate static func dispatchActiveRecordingEvent(
        _ event: NSEvent,
        preferredWindow: NSWindow?
    ) -> Bool {
        guard KeyboardShortcutRecorderActivity.isAnyRecorderActive,
              event.type == .keyDown || event.type == .systemDefined,
              let recorder = activeRecordingCandidate(preferredWindow: preferredWindow) else {
            return false
        }

        return recorder.consumeRecordingEvent(event)
    }

    private static func activeRecordingCandidate(preferredWindow: NSWindow?) -> ShortcutRecorderNSButton? {
        if let activeRecorder, activeRecorder.isRecording {
            return activeRecorder
        }

        let responders = [
            preferredWindow?.firstResponder,
            NSApp.keyWindow?.firstResponder,
            NSApp.mainWindow?.firstResponder,
        ]

        return responders.compactMap { $0 as? ShortcutRecorderNSButton }.first { $0.isRecording }
    }

    private func consumeRecordingEvent(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        _ = handleRecordingEvent(event)
        return true
    }

#if DEBUG
    var debugIsRecording: Bool {
        isRecording
    }

    var debugHasPendingRejection: Bool {
        hasPendingRejection
    }

    func debugSetPendingChordStart(_ stroke: ShortcutStroke?) {
        isRecording = true
        pendingChordStart = stroke
        updateTitle()
    }

    func debugHandleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        handleRecordingEvent(event)
    }

    func debugHandleMonitoredRecordingEvent(_ event: NSEvent) -> NSEvent? {
        handleMonitoredRecordingEvent(event)
    }
#endif

    isolated deinit {
        stopRecording()
        NotificationCenter.default.removeObserver(
            self,
            name: KeyboardShortcutRecorderActivity.stopAllNotification,
            object: nil
        )
    }
}

enum ShortcutRecorderEventRouter {
    static func dispatchActiveRecordingEvent(
        _ event: NSEvent,
        preferredWindow: NSWindow?
    ) -> Bool {
        ShortcutRecorderNSButton.dispatchActiveRecordingEvent(event, preferredWindow: preferredWindow)
    }
}
