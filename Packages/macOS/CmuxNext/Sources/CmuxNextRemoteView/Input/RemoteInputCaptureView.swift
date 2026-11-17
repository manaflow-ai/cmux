import AppKit
import CmuxNextDesign
import CmuxNextCompat

/// The pane's input surface, over the video. It takes keyboard focus on
/// click; while it is first responder in control mode, keys, pointer,
/// buttons and scroll go to the host. Coordinates are flipped like stream
/// pixels. With the `cursor` cap the local pointer wears the remote shape
/// (`RemoteCursorPresentation`); otherwise it stays the system arrow.
final class RemoteInputCaptureView: NSView, MouseButtonForwarding {
    let controller = RemoteInputController()
    /// The current image placement, from the video view.
    var geometry: () -> RemoteViewGeometry? = { nil }
    /// Called when focus or the mode changes so the pane can update chrome.
    var onFocusChange: ((Bool) -> Void)?
    /// A mouse button went down on the surface (before it is sent).
    var onMouseDown: (() -> Void)?
    var controlMode = false {
        didSet { updateActive() }
    }
    /// False: clicks and scrolls pass through to what is under the surface
    /// (a state card over the picture), never to the host.
    var acceptsPointer = true

    private var isFirstResponder = false
    private var markedText = NSAttributedString()
    /// The key event being interpreted by the input method.
    private var interpretingEvent: NSEvent?

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { acceptsPointer ? super.hitTest(point) : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
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

    private var keyObservers: [MainActorObservation] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.removeAll()
        if window == nil, isFirstResponder { isFirstResponder = false }
        if let window {
            // A window that stops being key takes the keyboard with it: release held keys.
            keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                MainActorObservation(name, object: window) { [weak self] in
                    self?.updateActive()
                }
            }
        }
        updateActive()
    }

    /// Read by mouse Back and Forward (`MouseSideButtons`): in control mode buttons 4 and 5 go
    /// to the host like every other button, so cmux does not navigate on them.
    var forwardsMouseButtons: Bool { controlMode }

    private func updateActive() {
        let active = controlMode && isFirstResponder && window?.isKeyWindow != false
        guard active != controller.isActive else { return }
        controller.isActive = active
        // Input now goes to the host, or stopped: the pane re-decides which cursor shows.
        onPointerChange?()
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

    /// The pointer positions sent to the host (stream pixels), to tell its echo of our
    /// pointer from the remote moving its cursor (`RemoteCursorPresentation`).
    private(set) var echo = RemotePointerEcho()
    /// Whether the local pointer is over the picture.
    private(set) var pointerInImage = false
    /// The pointer moved, entered or left: the pane re-decides which cursor shows.
    var onPointerChange: (() -> Void)?
    /// The cursor the local pointer wears over the picture (nil: the system arrow).
    var localCursor: NSCursor? {
        didSet {
            guard localCursor !== oldValue else { return }
            applyLocalCursor()
        }
    }

    /// Sets the local cursor at once while the pointer is over the surface (cursorUpdate
    /// fires only on entry, a remote shape change must not wait for it).
    private func applyLocalCursor() {
        guard pointerInImage, window?.isKeyWindow == true else { return }
        (localCursor ?? .arrow).set()
    }

    override func cursorUpdate(with event: NSEvent) { (pointerInImage ? localCursor ?? .arrow : .arrow).set() }

    override func mouseEntered(with event: NSEvent) { trackPointer(event) }
    override func mouseExited(with event: NSEvent) { setPointerInImage(false) }
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

    private func trackPointer(_ event: NSEvent) {
        guard let geometry = geometry() else { return setPointerInImage(false) }
        setPointerInImage(geometry.imageRect.contains(convert(event.locationInWindow, from: nil)))
    }

    private func setPointerInImage(_ inside: Bool) {
        let changed = inside != pointerInImage
        pointerInImage = inside
        if changed, inside { applyLocalCursor() }
        if changed, !inside { NSCursor.arrow.set() }
        onPointerChange?()
    }

    /// Sends the pointer and remembers it (only while input goes to the host).
    private func sendPointer(_ pixel: (x: Int32, y: Int32)) {
        guard controller.isActive else { return }
        controller.pointer(pixel)
        echo.record(CGPoint(x: Double(pixel.x), y: Double(pixel.y)), at: .now)
    }

    private func movePointer(_ event: NSEvent, clamped: Bool) {
        guard let geometry = geometry() else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inside = geometry.imageRect.contains(point)
        if clamped {
            sendPointer(geometry.clampedStreamPixel(at: point))
        } else if let pixel = geometry.streamPixel(at: point) {
            sendPointer(pixel)
        }
        setPointerInImage(inside)
    }

    private func press(_ event: NSEvent, down: Bool) {
        if down { onMouseDown?() }
        if down, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let geometry = geometry(), let button = RemoteMouseButton(event: event) else { return }
        let point = convert(event.locationInWindow, from: nil)
        if down {
            guard let pixel = geometry.streamPixel(at: point) else { return }
            controller.button(button, down: true, at: pixel)
            if controller.isActive { echo.record(CGPoint(x: Double(pixel.x), y: Double(pixel.y)), at: .now) }
        } else {
            let pixel = geometry.clampedStreamPixel(at: point)
            controller.button(button, down: false, at: pixel)
            if controller.isActive { echo.record(CGPoint(x: Double(pixel.x), y: Double(pixel.y)), at: .now) }
        }
        onPointerChange?()
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
