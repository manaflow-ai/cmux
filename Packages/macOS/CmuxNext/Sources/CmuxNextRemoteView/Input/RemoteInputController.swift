import AppKit
import Carbon.HIToolbox

/// Turns AppKit events into `RemoteInputEvent`s for the sink. Containment:
/// nothing is sent unless `isActive` (control mode and the capture view is
/// first responder); deactivating sends ups for every held key and button,
/// so nothing stays pressed on the host.
@MainActor
final class RemoteInputController {
    enum KeyDecision: Equatable {
        /// Sent (or swallowed); the view stops here.
        case handled
        /// Not ours: let AppKit (menus, cmux shortcuts) have it.
        case local
        /// Pass through the input method; committed text arrives in `commitText`.
        case textInput
    }

    weak var sink: (any RemoteViewInputSink)?
    var settings = RemoteDesktopSettings()
    var releaseChord = RemoteReleaseChord.default
    /// The App's cmux shortcut matcher (KeyboardShortcutSettings).
    var isLocalShortcut: (NSEvent) -> Bool = { _ in false }
    var inputSourceIsASCIICapable: () -> Bool = RemoteInputController.currentInputSourceIsASCIICapable
    /// The view returns the keyboard to the viewer (resigns first responder).
    var onReleaseKeyboard: (() -> Void)?
    /// Control mode and first responder. Turning it off releases everything.
    var isActive = false {
        didSet { if oldValue, !isActive { releaseAll() } }
    }

    private(set) var keyboard = RemoteKeyboardState()
    private var scroll = RemoteScrollAccumulator()
    /// Keys whose down went to the input method: their ups are not sent.
    private var textRoutedKeys: Set<UInt16> = []

    func keyDown(_ event: NSEvent) -> KeyDecision {
        let route = RemoteKeyboardPolicy.route(
            keyCode: event.keyCode, modifiers: event.modifierFlags, mode: settings.keyboardMode,
            sendSystemShortcuts: settings.sendSystemShortcuts,
            inputSourceIsASCIICapable: inputSourceIsASCIICapable(), releaseChord: releaseChord,
            isLocalShortcut: !settings.sendSystemShortcuts && isLocalShortcut(event))
        switch route {
        case .releaseKeyboard:
            releaseAll()
            onReleaseKeyboard?()
            return .handled
        case .local:
            return .local
        case .physical:
            guard isActive else { return .local }
            emit(keyboard.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat))
            return .handled
        case .textInput:
            guard isActive else { return .local }
            textRoutedKeys.insert(event.keyCode)
            return .textInput
        }
    }

    func keyUp(_ event: NSEvent) {
        if textRoutedKeys.remove(event.keyCode) != nil { return }
        emit(keyboard.keyUp(keyCode: event.keyCode))
    }

    func flagsChanged(_ event: NSEvent) {
        guard isActive else { return }
        emit(keyboard.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags))
    }

    /// Text the input method committed (text mode, or auto with an IME).
    func commitText(_ text: String) {
        guard isActive, !text.isEmpty else { return }
        emit(RemoteInputEvent.textEvents(text))
    }

    /// The input method did not consume a key (e.g. Return while
    /// composing ended): send it as a physical key after all.
    func sendPhysical(for event: NSEvent) {
        guard isActive else { return }
        textRoutedKeys.remove(event.keyCode)
        emit(keyboard.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat))
    }

    func pointer(_ pixel: (x: Int32, y: Int32)) {
        guard isActive else { return }
        emit([.pointer(x: pixel.x, y: pixel.y)])
    }

    func button(_ button: RemoteMouseButton, down: Bool, at pixel: (x: Int32, y: Int32)) {
        if down {
            guard isActive else { return }
            emit([.pointer(x: pixel.x, y: pixel.y)] + keyboard.buttonDown(button))
        } else {
            emit(keyboard.buttonUp(button))
        }
    }

    func scroll(_ event: NSEvent) {
        guard isActive else { return }
        let precise = event.hasPreciseScrollingDeltas
        if let scrollEvent = scroll.add(
            deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), precise: precise,
            phase: event.phase, momentumPhase: event.momentumPhase) {
            emit([scrollEvent])
        }
    }

    /// Ups for everything held; called on focus loss, mode change, release chord.
    func releaseAll() {
        textRoutedKeys.removeAll()
        emit(keyboard.releaseAll())
    }

    private func emit(_ events: [RemoteInputEvent]) {
        guard let sink else { return }
        for event in events { sink.send(event) }
    }

    /// Whether the selected input source can type ASCII (false for an IME
    /// such as Japanese kana input), for `keyboard.mode = auto`.
    nonisolated static func currentInputSourceIsASCIICapable() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return true }
        let value = Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }
}
