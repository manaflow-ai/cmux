import AppKit

/// The Chief's screen (a frame drawn aspect-fit in the layer). While the person holds control of a
/// computer that takes input this way (``input`` set), it is the computer's mouse and keyboard: a
/// click, a drag, a scroll and, once it is first responder, a key press go to the computer in its
/// screen pixels. Otherwise it takes no events and a click reaches the view behind it (the chat's
/// popup opens the page).
@MainActor
final class HomeChiefComputerScreenView: NSView {
    /// A press moved at least this far (points) is a drag, not a click.
    static let dragSlop: CGFloat = 4
    /// Trackpad scrolling sends one step per this many points.
    static let preciseScrollStep: CGFloat = 24

    /// Where the person's input goes; nil while the Chief drives (or for a computer driven elsewhere).
    var input: ((HomeChiefComputerInput) -> Void)? {
        didSet {
            if input == nil, window?.firstResponder === self { window?.makeFirstResponder(nil) }
            window?.invalidateCursorRects(for: self)
        }
    }
    private var pressed: (point: CGPoint, pixel: (x: Int, y: Int))?
    private var scrolled: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { input != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { input != nil }

    /// The frame on show (the layer's contents); nil before the first frame.
    var image: CGImage? {
        didSet { layer?.contents = image }
    }
    /// The frame's size in pixels; nil before the first frame.
    var imageSize: CGSize? { image.map { CGSize(width: $0.width, height: $0.height) } }

    /// The computer's pixel under `point` (top-left origin, in a view `size` showing a frame `image`
    /// aspect-fit); nil outside the frame.
    static func pixel(at point: CGPoint, in size: CGSize, image: CGSize) -> (x: Int, y: Int)? {
        guard size.width > 0, size.height > 0, image.width > 0, image.height > 0 else { return nil }
        let scale = min(size.width / image.width, size.height / image.height)
        let shown = CGSize(width: image.width * scale, height: image.height * scale)
        let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)
        let x = (point.x - origin.x) / scale, y = (point.y - origin.y) / scale
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return nil }
        return (Int(x), Int(y))
    }

    /// A finished press: a drag when it moved, else a click (`count` the click count).
    static func press(from start: (x: Int, y: Int), startPoint: CGPoint, to end: (x: Int, y: Int), endPoint: CGPoint,
                      button: Int, count: Int) -> HomeChiefComputerInput {
        if hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y) >= dragSlop {
            return .drag(fromX: start.x, fromY: start.y, toX: end.x, toY: end.y)
        }
        return .click(x: start.x, y: start.y, button: button, count: max(1, count))
    }

    /// The scroll steps for `delta` points of scrolling added to `carried` (what was left over), and
    /// what is left over now. Positive is up (the content moves down).
    static func scrollSteps(delta: CGFloat, carried: CGFloat, precise: Bool) -> (steps: Int, carried: CGFloat) {
        let step = precise ? preciseScrollStep : 1
        let total = carried + delta
        let steps = Int(total / step)
        return (steps, total - CGFloat(steps) * step)
    }

    private func pixel(_ event: NSEvent) -> (point: CGPoint, pixel: (x: Int, y: Int))? {
        guard let image = imageSize else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return Self.pixel(at: point, in: bounds.size, image: image).map { (point, $0) }
    }

    override func resetCursorRects() {
        if input != nil { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func mouseDown(with event: NSEvent) {
        guard input != nil else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        pressed = pixel(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard input != nil else { return super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let input else { return super.mouseUp(with: event) }
        defer { pressed = nil }
        guard let start = pressed else { return }
        // A release outside the frame ends the drag at its edge: the last pixel inside is not known, so
        // it counts as a click where it began.
        let end = pixel(event) ?? start
        // Each press is one click: a double-click arrives as two, which the computer counts as a double-click.
        input(Self.press(from: start.pixel, startPoint: start.point, to: end.pixel, endPoint: end.point, button: 1, count: 1))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard input != nil else { return super.rightMouseDown(with: event) }
        window?.makeFirstResponder(self)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let input else { return super.rightMouseUp(with: event) }
        guard let at = pixel(event) else { return }
        input(.click(x: at.pixel.x, y: at.pixel.y, button: 3, count: 1))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let input, let at = pixel(event) else { return super.scrollWheel(with: event) }
        let vertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        let delta = vertical ? event.scrollingDeltaY : event.scrollingDeltaX
        let result = Self.scrollSteps(delta: delta, carried: scrolled, precise: event.hasPreciseScrollingDeltas)
        scrolled = result.carried
        guard result.steps != 0 else { return }
        let direction = vertical ? (result.steps > 0 ? "up" : "down") : (result.steps > 0 ? "left" : "right")
        input(.scroll(x: at.pixel.x, y: at.pixel.y, direction: direction, amount: abs(result.steps)))
    }

    /// A Command or Control chord while the person drives goes to the computer (Command-L to its
    /// browser), not to cmux's menus, when no cmux shortcut took it first. Quit, Hide and Minimize stay the Mac's.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mac = event.modifierFlags.contains(.command) && ["q", "h", "m"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "")
        guard input != nil, !mac, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let input else { return super.keyDown(with: event) }
        guard let key = HomeChiefComputerKeys.input(keyCode: event.keyCode, characters: event.characters,
                                                    bare: event.charactersIgnoringModifiers,
                                                    modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)) else { return }
        input(key)
    }
}
