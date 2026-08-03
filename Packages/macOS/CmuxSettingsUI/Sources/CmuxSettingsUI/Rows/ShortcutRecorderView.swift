import AppKit
import CmuxFoundation
import CmuxSettings

public final class RecorderHostButton: NSButton {
    /// Tracks the recorder that is currently capturing keystrokes so a
    /// click on a different recorder can stop the previous one. Mirrors
    /// legacy `ShortcutRecorderNSButton.activeRecorder` /
    /// `KeyboardShortcutRecorderActivity.stopAllRecording()` — without
    /// it, clicking a second recorder leaves the first still
    /// installing event monitors and racing for keystrokes.
    private static weak var activeRecorder: RecorderHostButton?

    /// Whether a recorder is currently armed and capturing keystrokes for
    /// rebinding.
    ///
    /// The app's global keyboard-shortcut monitor reads this to stand down
    /// while a recorder is active, so app- and menu-level key equivalents
    /// (⌘W, ⌃1…9, …) reach the armed recorder to be recorded instead of
    /// firing their action. This mirrors the role the app-target
    /// `KeyboardShortcutRecorderActivity.isAnyRecorderActive` flag plays for
    /// the legacy `ShortcutRecorderNSButton`; the package recorder cannot
    /// import that app-target type, so it publishes its own read-only signal
    /// for the composition root to consult.
    public static var isActivelyRecording: Bool {
        activeRecorder?.isRecording ?? false
    }

    /// Posted (on the main thread) whenever ``isActivelyRecording`` changes —
    /// i.e. a package recorder arms or disarms.
    ///
    /// The app-target's system-wide hotkey registrar (`GlobalHotkeyManager`)
    /// is event-driven: it re-evaluates Carbon hotkey registration only when
    /// it is told recorder activity changed. The legacy recorder drives that
    /// via `KeyboardShortcutRecorderActivity.didChangeNotification`; the
    /// package recorder cannot reach that app-target type, so it publishes
    /// this notification. The composition root observes it and unregisters
    /// system-wide hotkeys while ``isActivelyRecording`` is `true`, so a global
    /// hotkey being rebound in Settings is captured instead of firing.
    // `nonisolated` so the nonisolated `deinit` teardown path can post it.
    public nonisolated static let activeRecordingDidChangeNotification = Notification.Name(
        "com.cmux.settingsUI.recorderActiveRecordingDidChange"
    )

    public var placeholder: String = ""
    public var chordsEnabled: Bool = false
    /// Whether the first recorded stroke must include Command, Option, Control, or Shift.
    ///
    /// The default is `true` so package-hosted settings rows cannot accidentally
    /// bind a plain typing key as an app-level shortcut. Content-scoped actions
    /// that intentionally use bare keys may set this to `false`.
    public var firstStrokeRequiresModifier: Bool = true
    public var onStroke: ((ShortcutStroke) -> Void)?
    public var onChord: ((StoredShortcut) -> Void)?
    public var onBareKeyRejected: (() -> Void)?

    // Read access is `internal` so the test target can observe recording
    // state via `@testable import`; writes stay `private` to this view.
    private(set) var isRecording = false
    private var pendingFirst: ShortcutStroke?
    private var hasPendingRejection = false
    // `deinit` is nonisolated and must remove the local event monitor; the
    // token is set/cleared only on the main thread (this is a main-thread
    // AppKit view), so reading it from the nonisolated deinit is safe.
    private nonisolated(unsafe) var eventMonitor: Any?
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // If AppKit tears us down while still armed (without a resignFirstResponder
        // that would call stopRecording), the start-notification's effect — Carbon
        // global hotkeys unregistered — would otherwise persist. The `activeRecorder`
        // weak ref nils as we deinit, so `isActivelyRecording` already reads false;
        // post the change so SystemWideHotkeyController re-registers (issue #5189).
        if isRecording {
            NotificationCenter.default.post(name: Self.activeRecordingDidChangeNotification, object: nil)
        }
    }

    private func configure() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        // Match legacy `ShortcutRecorderNSButton`, which rendered the
        // recorded chord in the default `.regular` system control font
        // for a `.rounded` bezel NSButton. When this button is hosted
        // inside AppKit via `NSViewController`, the ambient
        // `controlSize` environment can shrink the button to `.small`,
        // which swaps in the small system font and makes the shortcut
        // text visibly smaller/lighter than the legacy in-app control.
        // Pin both the control size and the font explicitly so the
        // package recorder renders byte-for-byte like legacy regardless
        // of the surrounding AppKit environment.
        controlSize = .regular
        applyFont()
        if fontMagnificationObserver == nil {
            fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
                self?.applyFont()
            }
        }
        target = self
        action = #selector(buttonClicked)
    }

    private func applyFont() {
        font = GlobalFontMagnification.systemFont(ofSize: NSFont.systemFontSize(for: .regular))
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            startRecording()
        }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        stopRecording()
        return result
    }

    @objc private func buttonClicked() {
        if isRecording {
            stopRecording()
        } else if window?.firstResponder === self {
            // Already first responder (e.g. the user just clicked to
            // cancel an in-progress recording, which stops recording but
            // keeps focus). `makeFirstResponder(self)` would be a no-op
            // here and never call `becomeFirstResponder`, so start
            // recording directly — otherwise a third click can't
            // re-enter recording mode.
            startRecording()
        } else {
            window?.makeFirstResponder(self)
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        // Stop any other recorder before claiming the active slot so
        // only one button is consuming keystrokes at a time. Matches
        // legacy `KeyboardShortcutRecorderActivity.stopAllRecording()`
        // behavior invoked from `ShortcutRecorderNSButton.startRecording`.
        if let previous = Self.activeRecorder, previous !== self {
            previous.stopRecording()
        }
        isRecording = true
        Self.activeRecorder = self
        pendingFirst = nil
        hasPendingRejection = false
        installEventMonitor()
        refreshTitle()
        Self.postActiveRecordingDidChange()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if Self.activeRecorder === self {
            Self.activeRecorder = nil
        }
        pendingFirst = nil
        removeEventMonitor()
        refreshTitle()
        Self.postActiveRecordingDidChange()
    }

    /// Stops an active recording session idempotently. Safe to call on any recorder
    /// regardless of whether it is currently recording — used by `native teardown`
    /// so that a cell being torn down (or recycled for a different action in Task 5)
    /// does not leave an armed recorder pointed at the wrong action.
    public func cancelRecordingIfActive() {
        guard isRecording else { return }
        pendingFirst = nil  // explicit for clarity; stopRecording() nils it too
        stopRecording()
    }

    private static func postActiveRecordingDidChange() {
        NotificationCenter.default.post(name: activeRecordingDidChangeNotification, object: nil)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handleRecordingEvent(event)
        return true
    }

    public override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handleRecordingEvent(event)
    }

    /// Installs a local NSEvent monitor that drains key-down (and
    /// system-defined media-key) events to this recorder while it is
    /// active. Without `.keyDown`, ⌘W / ⌘Q / ⌘N and similar
    /// menu-equivalent strokes fire the app menu before reaching the
    /// button, so the user cannot bind them. Without `.systemDefined`,
    /// media keys (Play/Pause, Volume, Brightness, Next/Previous Track)
    /// are never delivered, so they cannot be recorded either —
    /// matching the legacy `ShortcutRecorderNSButton` monitor mask.
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { [weak self] event in
            guard let self, self.isRecording, self.window?.firstResponder === self else { return event }
            self.handleRecordingEvent(event)
            return nil
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func handleRecordingEvent(_ event: NSEvent) {
        // Escape aborts a chord-in-progress without committing.
        if event.keyCode == 53 /* Escape */ {
            pendingFirst = nil
            stopRecording()
            return
        }

        guard let key = recordedShortcutKey(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else { return }

        let hasModifier = event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.option)
            || event.modifierFlags.contains(.control)
            || event.modifierFlags.contains(.shift)

        let stroke = ShortcutStroke(
            key: key,
            command: event.modifierFlags.contains(.command),
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control),
            keyCode: event.keyCode
        )

        // Legacy ShortcutRecorderNSButton requires a modifier on the
        // first stroke so users cannot accidentally bind a bare letter
        // as a global keyboard shortcut. The chord-pending second
        // stroke does not require a modifier (matching legacy).
        if pendingFirst == nil, firstStrokeRequiresModifier, !hasModifier {
            hasPendingRejection = true
            refreshTitle()
            onBareKeyRejected?()
            return
        }

        if chordsEnabled, let first = pendingFirst {
            pendingFirst = nil
            hasPendingRejection = false
            let chord = StoredShortcut(first: first, second: stroke)
            onChord?(chord)
            stopRecording()
            return
        }

        if chordsEnabled, pendingFirst == nil {
            pendingFirst = stroke
            hasPendingRejection = false
            refreshTitle()
            return
        }

        hasPendingRejection = false
        onStroke?(stroke)
        stopRecording()
    }

    /// Clears the internal "pending rejection" state so the button
    /// stops displaying the "Press shortcut…" prompt after the user
    /// dismisses the validation banner via Undo. Mirrors the legacy
    /// `ShortcutRecorderNSButton.clearPendingRejection` flow used by
    /// `ShortcutRecorderButton.updateNSView` in legacy code.
    public func clearPendingRejection() {
        guard hasPendingRejection else { return }
        hasPendingRejection = false
        refreshTitle()
    }

    /// Recomputes the button title from the current recording / pending
    /// state. Called automatically on every state transition and by the
    /// AppKit native update path when the placeholder changes.
    public func refreshTitle() {
        if isRecording {
            if let pendingFirst {
                let format = String(localized: "shortcut.recorder.pendingChord", defaultValue: "%@ …")
                title = String.localizedStringWithFormat(format, shortcutStrokeDisplayString(pendingFirst))
            } else {
                title = String(localized: "shortcut.pressShortcut.prompt", defaultValue: "Press shortcut…")
            }
        } else if hasPendingRejection {
            title = String(localized: "shortcut.pressShortcut.prompt", defaultValue: "Press shortcut…")
        } else {
            title = placeholder
        }
    }

}
