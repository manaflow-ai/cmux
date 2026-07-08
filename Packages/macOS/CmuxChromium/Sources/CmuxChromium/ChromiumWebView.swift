public import AppKit
import QuartzCore

/// AppKit view that displays and drives one ``ChromiumSession``.
///
/// Rendering is zero-copy: the Content Shell compositor exports a `CAContext`
/// and this view mounts a `CALayerHost` with that context ID. The view is the
/// session's single event consumer — it folds events into the injected
/// ``ChromiumBrowserModel`` — so host at most one view per session.
@MainActor
public final class ChromiumWebView: NSView {
    private let session: ChromiumSession
    private let model: ChromiumBrowserModel
    private let keyTranslation = ChromiumKeyTranslation()
    private var eventTask: Task<Void, Never>?
    private var hostLayer: CALayer?
    private var hostedContextID: UInt32?
    private var lastSentSize: CGSize = .zero
    private var lastSentScale: CGFloat = 0
    private var mouseTrackingArea: NSTrackingArea?

    /// Creates a view driving `session` and projecting its state into `model`.
    public init(session: ChromiumSession, model: ChromiumBrowserModel) {
        self.session = session
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChromiumWebView does not support NSCoder")
    }

    public override var acceptsFirstResponder: Bool { true }

    /// Flipped so mouse coordinates match Blink's top-left-origin widget space.
    public override var isFlipped: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startEventTaskIfNeeded()
            sendResizeIfNeeded()
        }
    }

    public override func layout() {
        super.layout()
        hostLayer?.frame = bounds
        sendResizeIfNeeded()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sendResizeIfNeeded()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    public override func becomeFirstResponder() -> Bool {
        session.setFocus(true)
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        session.setFocus(false)
        return super.resignFirstResponder()
    }

    // MARK: - Events

    private func startEventTaskIfNeeded() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            guard let events = self?.session.events else { return }
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: ChromiumSessionEvent) {
        model.apply(event)
        switch event {
        case .ready(_, let contextID):
            if contextID != 0 {
                installLayerHost(contextID: contextID)
            }
            sendResizeIfNeeded(force: true)
        case .compositorChanged(let contextID):
            if contextID != 0 {
                installLayerHost(contextID: contextID)
            }
        case .disconnected:
            hostLayer?.removeFromSuperlayer()
            hostLayer = nil
            hostedContextID = nil
        case .navigationChanged, .surfaceTreeChanged, .log:
            break
        }
    }

    // MARK: - Rendering

    private func installLayerHost(contextID: UInt32) {
        guard contextID != hostedContextID else { return }
        hostLayer?.removeFromSuperlayer()
        // CALayerHost is the private-but-stable CoreAnimation class for
        // cross-process layer trees; instantiated by name to avoid an SPI import.
        guard let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type else {
            return
        }
        let host = hostClass.init()
        host.setValue(NSNumber(value: contextID), forKey: "contextId")
        host.frame = bounds
        host.contentsGravity = .topLeft
        layer?.addSublayer(host)
        hostLayer = host
        hostedContextID = contextID
    }

    private func sendResizeIfNeeded(force: Bool = false) {
        guard window != nil else { return }
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? 2
        guard size.width >= 1, size.height >= 1 else { return }
        if !force, size == lastSentSize, scale == lastSentScale {
            return
        }
        lastSentSize = size
        lastSentScale = scale
        session.resize(width: Int(size.width), height: Int(size.height), scale: scale)
    }

    // MARK: - Mouse input

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        forwardMouse(event, kind: .down, button: .left)
    }

    public override func mouseUp(with event: NSEvent) {
        forwardMouse(event, kind: .up, button: .left)
    }

    public override func mouseDragged(with event: NSEvent) {
        forwardMouse(event, kind: .move, button: .left)
    }

    public override func rightMouseDown(with event: NSEvent) {
        forwardMouse(event, kind: .down, button: .right)
    }

    public override func rightMouseUp(with event: NSEvent) {
        forwardMouse(event, kind: .up, button: .right)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        forwardMouse(event, kind: .move, button: .right)
    }

    public override func otherMouseDown(with event: NSEvent) {
        forwardMouse(event, kind: .down, button: .middle)
    }

    public override func otherMouseUp(with event: NSEvent) {
        forwardMouse(event, kind: .up, button: .middle)
    }

    public override func mouseMoved(with event: NSEvent) {
        forwardMouse(event, kind: .move, button: .left)
    }

    public override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        session.send(
            ChromiumMouseEvent(
                kind: .wheel,
                x: Float(location.x),
                y: Float(location.y),
                deltaX: Float(event.scrollingDeltaX),
                deltaY: Float(event.scrollingDeltaY),
                modifiers: UInt32(truncatingIfNeeded: event.modifierFlags.rawValue)
            )
        )
    }

    private func forwardMouse(_ event: NSEvent, kind: ChromiumMouseEvent.Kind, button: ChromiumMouseEvent.Button) {
        let location = convert(event.locationInWindow, from: nil)
        session.send(
            ChromiumMouseEvent(
                kind: kind,
                x: Float(location.x),
                y: Float(location.y),
                button: button,
                clickCount: UInt32(max(0, event.clickCount)),
                modifiers: UInt32(truncatingIfNeeded: event.modifierFlags.rawValue)
            )
        )
    }

    // MARK: - Keyboard input

    public override func keyDown(with event: NSEvent) {
        forwardKey(event, isKeyDown: true)
    }

    public override func keyUp(with event: NSEvent) {
        forwardKey(event, isKeyDown: false)
    }

    private func forwardKey(_ event: NSEvent, isKeyDown: Bool) {
        let keyCode = keyTranslation.windowsKeyCode(
            macKeyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers
        )
        let text = isKeyDown
            ? keyTranslation.text(
                characters: event.characters,
                isCommandPressed: event.modifierFlags.contains(.command)
            )
            : ""
        session.send(
            ChromiumKeyEvent(
                isKeyDown: isKeyDown,
                keyCode: keyCode,
                text: text,
                modifiers: UInt32(truncatingIfNeeded: event.modifierFlags.rawValue)
            )
        )
    }
}
