import AppKit

/// The pane's input surface, over the video. It takes keyboard focus on
/// click; while it is first responder in control mode, keys, pointer,
/// buttons and scroll go to the host. Coordinates are flipped like stream
/// pixels. The local cursor stays the system arrow (control mode draws the
/// native cursor locally, RD6).
final class RemoteInputCaptureView: NSView {
    let controller = RemoteInputController()
    /// The current image placement, from the video view.
    var geometry: () -> RemoteViewGeometry? = { nil }
    /// Called when focus or the mode changes so the pane can update chrome.
    var onFocusChange: ((Bool) -> Void)?
    var controlMode = false {
        didSet { updateActive() }
    }

    private var isFirstResponder = false
    private var markedText = NSAttributedString()
    /// The key event being interpreted by the input method.
    private var interpretingEvent: NSEvent?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func becomeFirstResponder() -> Bool {
        isFirstResponder = true
        updateActive()
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFirstResponder = false
        updateActive()
        inputContext?.discardMarkedText()
        markedText = NSAttributedString()
        onFocusChange?(false)
        return true
    }

    private var keyObservers: [any NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
        if window == nil, isFirstResponder { isFirstResponder = false }
        if let window {
            // A window that stops being key takes the keyboard with it: release held keys.
            keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateActive() } // main-proof: observer on queue: .main
                }
            }
        }
        updateActive()
    }

    private func updateActive() {
        controller.isActive = controlMode && isFirstResponder && window?.isKeyWindow != false
    }

    /// Gives the keyboard back to the viewer.
    func releaseKeyboard() {
        guard let window, window.firstResponder === self else { return }
        window.makeFirstResponder(nil)
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        return handleKeyDown(event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyDown(event) { super.keyDown(with: event) }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch controller.keyDown(event) {
        case .handled: return true
        case .local: return false
        case .textInput:
            interpretingEvent = event
            interpretKeyEvents([event])
            interpretingEvent = nil
            return true
        }
    }

    override func keyUp(with event: NSEvent) { controller.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { controller.flagsChanged(event) }

    // MARK: Pointer

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseMoved(with event: NSEvent) { movePointer(event, clamped: false) }
    override func mouseDragged(with event: NSEvent) { movePointer(event, clamped: true) }
    override func rightMouseDragged(with event: NSEvent) { movePointer(event, clamped: true) }
    override func otherMouseDragged(with event: NSEvent) { movePointer(event, clamped: true) }

    override func mouseDown(with event: NSEvent) { press(event, down: true) }
    override func mouseUp(with event: NSEvent) { press(event, down: false) }
    override func rightMouseDown(with event: NSEvent) { press(event, down: true) }
    override func rightMouseUp(with event: NSEvent) { press(event, down: false) }
    override func otherMouseDown(with event: NSEvent) { press(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { press(event, down: false) }

    override func scrollWheel(with event: NSEvent) { controller.scroll(event) }

    private func movePointer(_ event: NSEvent, clamped: Bool) {
        guard let geometry = geometry() else { return }
        let point = convert(event.locationInWindow, from: nil)
        if clamped {
            controller.pointer(geometry.clampedStreamPixel(at: point))
        } else if let pixel = geometry.streamPixel(at: point) {
            controller.pointer(pixel)
        }
    }

    private func press(_ event: NSEvent, down: Bool) {
        if down, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let geometry = geometry(), let button = RemoteMouseButton(appKitButtonNumber: event.buttonNumber) else { return }
        let point = convert(event.locationInWindow, from: nil)
        if down {
            guard let pixel = geometry.streamPixel(at: point) else { return }
            controller.button(button, down: true, at: pixel)
        } else {
            controller.button(button, down: false, at: geometry.clampedStreamPixel(at: point))
        }
    }
}

extension RemoteInputCaptureView: @MainActor NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSAttributedString()
        controller.commitText(text)
    }

    override func doCommand(by selector: Selector) {
        // The input method did not turn the key into text: send the key itself.
        if let event = interpretingEvent { controller.sendPhysical(for: event) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
    }

    func unmarkText() { markedText = NSAttributedString() }
    func selectedRange() -> NSRange { NSRange(location: markedText.length, length: 0) }
    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// The candidate window sits at the pane's center: the remote caret is
    /// unknown to the viewer.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let local = NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 18)
        guard let window else { return local }
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
