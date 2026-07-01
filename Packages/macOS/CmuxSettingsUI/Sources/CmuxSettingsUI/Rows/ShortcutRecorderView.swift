import AppKit
import CmuxFoundation
import CmuxSettings
import SwiftUI

/// AppKit-backed SwiftUI control that records a ``StoredShortcut``.
///
/// SwiftUI does not surface raw key-down events with modifier flags
/// usable for shortcut recording, so this view wraps an
/// `NSViewRepresentable` over an `NSButton` subclass that captures
/// `keyDown` and `performKeyEquivalent` while focused. Click the button
/// to enter recording mode; the button title changes to
/// "Press shortcut…" and the next keystroke is captured and yielded
/// via ``onStroke``.
///
/// When ``chordsEnabled`` is `true`, the recorder collects two
/// keystrokes in sequence — the second is the "chord" stroke,
/// modeled after tmux-style `Ctrl-B + p` bindings — and yields a
/// chorded ``StoredShortcut`` via ``onChord``. Pressing Escape during
/// the chord-pending state aborts the recording.
///
/// Mirrors the legacy `ShortcutRecorderButton` (NSButton with
/// `.rounded` bezel) used in the in-app Settings keyboard shortcuts
/// section so the package recorder is visually indistinguishable from
/// the legacy control. The recorder installs a local NSEvent monitor
/// while active so modifier combinations that would normally trigger
/// app menu items (⌘W, ⌘Q, ⌘N, etc.) are captured for recording
/// instead of firing the menu action.
public struct ShortcutRecorderView: NSViewRepresentable {
    private let onStroke: (ShortcutStroke) -> Void
    private let onChord: ((StoredShortcut) -> Void)?
    private let onBareKeyRejected: (() -> Void)?
    private let placeholder: String
    private let chordsEnabled: Bool
    private let hasPendingRejection: Bool
    private let firstStrokeRequiresModifier: Bool

    /// Creates a single-stroke recorder.
    ///
    /// The default `placeholder` is the legacy empty label
    /// (`shortcut.unbound.displayValue`, "None"), matching
    /// `StoredShortcut.displayString` for an unbound binding. When the
    /// action is unbound and the recorder is not focused, the box shows
    /// this label rather than a recording prompt — mirroring legacy
    /// `ShortcutRecorderNSButton` resting state.
    ///
    /// Set `firstStrokeRequiresModifier` to `false` only for content-scoped
    /// shortcuts that intentionally allow vim-style bare keys, such as
    /// diff-viewer navigation.
    public init(
        placeholder: String = String(localized: "shortcut.unbound.displayValue", defaultValue: "None"),
        hasPendingRejection: Bool = false,
        firstStrokeRequiresModifier: Bool = true,
        onStroke: @escaping (ShortcutStroke) -> Void,
        onBareKeyRejected: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self.hasPendingRejection = hasPendingRejection
        self.firstStrokeRequiresModifier = firstStrokeRequiresModifier
        self.onStroke = onStroke
        self.onChord = nil
        self.onBareKeyRejected = onBareKeyRejected
        self.chordsEnabled = false
    }

    /// Creates a recorder that can capture either a single stroke or
    /// a two-stroke chord. When the user enters chord mode, the
    /// recorder waits for a second keystroke and yields it via
    /// ``onChord``. Plain single-key recordings still fire
    /// ``onStroke``.
    ///
    /// Set `firstStrokeRequiresModifier` to `false` only for content-scoped
    /// shortcuts that intentionally allow vim-style bare keys, such as
    /// diff-viewer navigation. The chord-pending second stroke can always be
    /// bare, matching the legacy app-target recorder.
    public init(
        placeholder: String = String(localized: "shortcut.unbound.displayValue", defaultValue: "None"),
        chordsEnabled: Bool,
        hasPendingRejection: Bool = false,
        firstStrokeRequiresModifier: Bool = true,
        onStroke: @escaping (ShortcutStroke) -> Void,
        onChord: @escaping (StoredShortcut) -> Void,
        onBareKeyRejected: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self.hasPendingRejection = hasPendingRejection
        self.firstStrokeRequiresModifier = firstStrokeRequiresModifier
        self.onStroke = onStroke
        self.onChord = onChord
        self.onBareKeyRejected = onBareKeyRejected
        self.chordsEnabled = chordsEnabled
    }

    public func makeNSView(context: Context) -> RecorderHostButton {
        let button = RecorderHostButton()
        button.placeholder = placeholder
        button.chordsEnabled = chordsEnabled
        button.firstStrokeRequiresModifier = firstStrokeRequiresModifier
        button.onStroke = onStroke
        button.onChord = onChord
        button.onBareKeyRejected = onBareKeyRejected
        button.refreshTitle()
        return button
    }

    public func updateNSView(_ nsView: RecorderHostButton, context: Context) {
        nsView.placeholder = placeholder
        nsView.chordsEnabled = chordsEnabled
        nsView.firstStrokeRequiresModifier = firstStrokeRequiresModifier
        nsView.onStroke = onStroke
        nsView.onChord = onChord
        nsView.onBareKeyRejected = onBareKeyRejected
        if !hasPendingRejection {
            nsView.clearPendingRejection()
        }
        nsView.refreshTitle()
    }
}

/// Focusable AppKit `NSButton` host for ``ShortcutRecorderView``.
///
/// Mirrors the legacy `ShortcutRecorderNSButton` shape: a rounded
/// `NSButton` whose title swaps between the recorded shortcut, a
/// "Press shortcut…" prompt while recording, and a `"<first> …"`
/// preview while waiting for the second stroke of a chord. Installs
/// an `NSEvent.addLocalMonitorForEvents` monitor while recording so
/// menu-equivalent keystrokes (⌘W, ⌘Q, ⌘N, etc.) are captured for
/// recording instead of firing menu items.
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

    private var isRecording = false
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
        // inside SwiftUI via `NSViewRepresentable`, the ambient
        // `controlSize` environment can shrink the button to `.small`,
        // which swaps in the small system font and makes the shortcut
        // text visibly smaller/lighter than the legacy in-app control.
        // Pin both the control size and the font explicitly so the
        // package recorder renders byte-for-byte like legacy regardless
        // of the surrounding SwiftUI environment.
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

    private func startRecording() {
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

    private func stopRecording() {
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

    private func handleRecordingEvent(_ event: NSEvent) {
        // Escape aborts a chord-in-progress without committing.
        if event.keyCode == 53 /* Escape */ {
            pendingFirst = nil
            stopRecording()
            return
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }

        let hasModifier = event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.option)
            || event.modifierFlags.contains(.control)
            || event.modifierFlags.contains(.shift)

        let stroke = ShortcutStroke(
            key: chars.lowercased(),
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
    /// SwiftUI `updateNSView` path when the placeholder changes.
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

#if DEBUG
extension RecorderHostButton {
    var debugIsRecording: Bool {
        isRecording
    }

    func debugStartRecording() {
        startRecording()
    }

    func debugStopRecording() {
        stopRecording()
    }

    func debugHandleRecordingEvent(_ event: NSEvent) {
        handleRecordingEvent(event)
    }
}
#endif
