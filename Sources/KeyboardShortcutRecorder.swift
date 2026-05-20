import AppKit
import SwiftUI

/// View for recording a keyboard shortcut
struct KeyboardShortcutRecorder: View {
    let label: String
    var subtitle: String? = nil
    @Binding var shortcut: StoredShortcut
    var displayString: (StoredShortcut) -> String = { $0.displayString }
    var transformRecordedShortcut: (StoredShortcut) -> KeyboardShortcutSettings.RecordedShortcutResolution = {
        .accepted($0)
    }
    var validationMessage: String? = nil
    var validationButtonTitle: String? = nil
    var onValidationButtonPressed: (() -> Void)? = nil
    var undoButtonTitle: String? = nil
    var onUndoButtonPressed: (() -> Void)? = nil
    var hasPendingRejection: Bool = false
    var isDisabled: Bool = false
    var onRecordingChanged: (Bool) -> Void = { _ in }
    var onRecorderFeedbackChanged: (ShortcutRecorderRejectedAttempt?) -> Void = { _ in }
    @State private var isRecording = false
    @State private var restoreShortcut: StoredShortcut?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                ShortcutRecorderButton(
                    shortcut: $shortcut,
                    isRecording: $isRecording,
                    hasPendingRejection: hasPendingRejection,
                    displayString: displayString,
                    transformRecordedShortcut: transformRecordedShortcut,
                    onRecordingChanged: onRecordingChanged,
                    onRecorderFeedbackChanged: onRecorderFeedbackChanged
                )
                    .frame(width: 160)
                    .disabled(isDisabled)

                let canRestoreShortcut = shortcut.isUnbound && restoreShortcut != nil
                Button {
                    KeyboardShortcutRecorderActivity.stopAllRecording()

                    if canRestoreShortcut, let restoreShortcut {
                        shortcut = restoreShortcut
                        self.restoreShortcut = nil
                    } else if !shortcut.isUnbound {
                        restoreShortcut = shortcut
                        shortcut = .unbound
                    }

                    onRecorderFeedbackChanged(nil)
                } label: {
                    Image(systemName: canRestoreShortcut ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .disabled(isDisabled || (shortcut.isUnbound && restoreShortcut == nil))
                .safeHelp(
                    canRestoreShortcut
                        ? String(localized: "shortcut.recorder.restore.help", defaultValue: "Restore previous shortcut")
                        : String(localized: "shortcut.recorder.clear.help", defaultValue: "Unbind shortcut")
                )
                .accessibilityLabel(
                    canRestoreShortcut
                        ? String(localized: "shortcut.recorder.restore", defaultValue: "Restore")
                        : String(localized: "shortcut.recorder.clear", defaultValue: "Unbind")
                )
                .accessibilityIdentifier("ShortcutRecorderClearRestoreButton")
            }

            if let validationMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)

                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)

                    if let validationButtonTitle, let onValidationButtonPressed {
                        Button(validationButtonTitle, action: onValidationButtonPressed)
                            .buttonStyle(.link)
                            .font(.caption)
                    }

                    if let undoButtonTitle, let onUndoButtonPressed {
                        Button(undoButtonTitle, action: onUndoButtonPressed)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.12))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.35), lineWidth: 1)
                }
                .accessibilityIdentifier("ShortcutRecorderValidationMessage")
            }
        }
        .onChange(of: shortcut) { _, newValue in
            if !newValue.isUnbound {
                restoreShortcut = nil
            }
        }
    }
}

private struct ShortcutRecorderButton: NSViewRepresentable {
    @Binding var shortcut: StoredShortcut
    @Binding var isRecording: Bool
    var hasPendingRejection: Bool = false
    let displayString: (StoredShortcut) -> String
    let transformRecordedShortcut: (StoredShortcut) -> KeyboardShortcutSettings.RecordedShortcutResolution
    let onRecordingChanged: (Bool) -> Void
    let onRecorderFeedbackChanged: (ShortcutRecorderRejectedAttempt?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSButton {
        let button = ShortcutRecorderNSButton()
        button.shortcut = shortcut
        button.displayString = displayString
        button.transformRecordedShortcut = transformRecordedShortcut
        button.onShortcutRecorded = { newShortcut in
            shortcut = newShortcut
            isRecording = false
            onRecorderFeedbackChanged(nil)
        }
        button.onRecordingChanged = { recording in
            isRecording = recording
            onRecordingChanged(recording)
        }
        button.onRecorderFeedbackChanged = onRecorderFeedbackChanged
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderNSButton, context: Context) {
        nsView.shortcut = shortcut
        nsView.displayString = displayString
        nsView.transformRecordedShortcut = transformRecordedShortcut
        nsView.onRecordingChanged = { recording in
            isRecording = recording
            onRecordingChanged(recording)
        }
        nsView.onRecorderFeedbackChanged = onRecorderFeedbackChanged
        if !hasPendingRejection {
            nsView.clearPendingRejection()
        }
        nsView.updateTitle()
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
            switch ShortcutStroke.recordingResult(from: event, requireModifier: true) {
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

    deinit {
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
