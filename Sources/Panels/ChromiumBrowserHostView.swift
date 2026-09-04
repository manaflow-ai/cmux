import AppKit
import CmuxBrowser
import Foundation

/// AppKit surface for an out-of-process Chromium page.
///
/// `chrome-headless-shell` has no native NSView to embed. The managed session
/// streams PNG frames over CDP; this view paints the latest frame and forwards
/// the minimum native input set back through CDP. The child process remains
/// fully isolated from cmux, including when its renderer crashes.
@MainActor
final class ChromiumBrowserHostView: NSView {
    private let frameDecoder = ChromiumFrameDecoder()
    private let imageView = NSImageView(frame: .zero)
    private weak var session: ChromiumBrowserSession?
    private var frameTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var viewportTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var pointerTrackingArea: NSTrackingArea?
    private var lastViewport: CGSize = .zero
    private var automationViewport: BrowserViewport?
    private var sessionIsReady = false
    private var inputGeneration: UInt64 = 0
    private var pendingInput: [(key: String?, operation: @Sendable (ChromiumBrowserSession) async throws -> Void)] = []
    private var requestedViewport: (width: Int, height: Int, scale: Double)?
    private var hasStarted = false

    private var deviceScaleFactor: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    var onSnapshot: ((ChromiumSessionSnapshot) -> Void)?
    var onInputFailure: ((any Error) -> Void)?
    var onFocus: (() -> Void)?

    init(session: ChromiumBrowserSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        frameTask?.cancel()
        stateTask?.cancel()
        viewportTask?.cancel()
        inputTask?.cancel()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocus?()
        }
        return accepted
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0,
              bounds.contains(convert(point, from: superview)) else { return nil }
        // The image view is presentation-only. Keep all pointer events on the
        // host so they can be translated into CDP input for the child process.
        return self
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard let session else { return }

        let decoder = frameDecoder
        frameTask = Task { [weak self, weak session] in
            guard let session else { return }
            let frames = await session.frames()
            for await frame in frames {
                guard !Task.isCancelled else { return }
                guard let decoded = await decoder.decode(frame), !Task.isCancelled else { continue }
                await MainActor.run {
                    guard let self else { return }
                    let expected = self.automationViewport?.size ?? self.bounds.size
                    guard expected.width > 0, expected.height > 0 else { return }
                    // A resize can leave one old compositor frame in flight.
                    // Never stretch that frame into a different aspect ratio.
                    let expectedHeight = Double(decoded.image.width) * expected.height / expected.width
                    guard abs(Double(decoded.image.height) - expectedHeight) <= 2 else { return }
                    self.imageView.image = NSImage(cgImage: decoded.image, size: .zero)
                    self.needsDisplay = true
                }
            }
        }

        stateTask = Task { [weak self, weak session] in
            guard let session else { return }
            let snapshots = await session.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.onSnapshot?(snapshot)
                    if case .running = snapshot.state, !self.sessionIsReady {
                        self.sessionIsReady = true
                        // The first layout can happen before the child/CDP
                        // connection is ready. Retry the same geometry when
                        // the running signal arrives instead of leaving the
                        // renderer at its 1280x800 default viewport.
                        self.lastViewport = .zero
                        self.updateViewportIfNeeded()
                    }
                }
            }
        }
        updateViewportIfNeeded()
    }

    func stop() {
        inputGeneration &+= 1
        pendingInput.removeAll()
        requestedViewport = nil
        sessionIsReady = false
        frameTask?.cancel()
        stateTask?.cancel()
        viewportTask?.cancel()
        inputTask?.cancel()
        frameTask = nil
        stateTask = nil
        viewportTask = nil
        inputTask = nil
        hasStarted = false
        imageView.image = nil
    }

    override func layout() {
        super.layout()
        imageView.frame = displayLayout?.frame ?? bounds
        updateViewportIfNeeded()
    }

    func setAutomationViewport(_ viewport: BrowserViewport?) {
        guard automationViewport != viewport else { return }
        automationViewport = viewport
        lastViewport = .zero
        needsLayout = true
        updateViewportIfNeeded()
    }

    private var displayLayout: BrowserViewportLayout? {
        BrowserViewportLayout(containerBounds: bounds, viewport: automationViewport)
    }

    private func pagePoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        guard let layout = displayLayout, layout.scale > 0 else { return point }
        return CGPoint(x: (point.x - layout.frame.minX) / layout.scale,
                       y: (layout.frame.maxY - point.y) / layout.scale)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let replacement = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
            owner: self
        )
        addTrackingArea(replacement)
        pointerTrackingArea = replacement
    }

    private func updateViewportIfNeeded() {
        let size = automationViewport?.size ?? bounds.size
        guard size.width > 1, size.height > 1, size != lastViewport else { return }
        lastViewport = size
        guard let session else { return }
        // CDP viewport dimensions are CSS points. The device scale factor is
        // sent separately so mouse coordinates and DOM geometry stay in the
        // same coordinate space as selector automation.
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        requestedViewport = (width, height, max(1, Double(deviceScaleFactor)))
        guard sessionIsReady, viewportTask == nil else { return }
        let generation = inputGeneration
        viewportTask = Task { [weak self, session] in
            guard let self else { return }
            defer { if inputGeneration == generation { viewportTask = nil } }
            while !Task.isCancelled, let viewport = requestedViewport {
                requestedViewport = nil
                do {
                    try await session.setViewport(width: viewport.width, height: viewport.height,
                                                  deviceScaleFactor: viewport.scale)
                } catch {
                    if !Task.isCancelled { onInputFailure?(error) }
                }
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lastViewport = .zero
        updateViewportIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        focusForPointerInput()
        sendMouse(event, type: "mousePressed")
    }

    override func mouseUp(with event: NSEvent) {
        sendMouse(event, type: "mouseReleased")
    }

    override func rightMouseDown(with event: NSEvent) {
        focusForPointerInput()
        sendMouse(event, type: "mousePressed", button: "right")
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouse(event, type: "mouseReleased", button: "right")
    }

    override func otherMouseDown(with event: NSEvent) {
        focusForPointerInput()
        sendMouse(event, type: "mousePressed", button: "middle")
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouse(event, type: "mouseReleased", button: "middle")
    }

    override func mouseMoved(with event: NSEvent) {
        sendMouse(event, type: "mouseMoved", button: "none", clickCount: 0)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMouse(event, type: "mouseMoved", button: "left", clickCount: 0)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMouse(event, type: "mouseMoved", button: "right", clickCount: 0)
    }

    private func enqueueInput(
        coalescingKey: String? = nil,
        _ operation: @escaping @Sendable (ChromiumBrowserSession) async throws -> Void
    ) {
        if let coalescingKey, pendingInput.last?.key == coalescingKey {
            pendingInput[pendingInput.count - 1] = (coalescingKey, operation)
        } else {
            guard pendingInput.count < 128 else {
                onInputFailure?(ChromiumBrowserDiagnostic.commandQueueFull)
                return
            }
            pendingInput.append((coalescingKey, operation))
        }
        guard inputTask == nil else { return }
        let generation = inputGeneration
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer { if inputGeneration == generation { inputTask = nil } }
            while !Task.isCancelled, hasStarted, inputGeneration == generation,
                  !pendingInput.isEmpty, let session {
                let next = pendingInput.removeFirst()
                do { try await next.operation(session) }
                catch { if !Task.isCancelled { onInputFailure?(error) } }
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = pagePoint(for: event)
        let x = Double(point.x)
        let y = Double(point.y)
        let deltaX = Double(event.scrollingDeltaX)
        let deltaY = Double(-event.scrollingDeltaY)
        let modifiers = ChromiumKeyMapping.modifiers(event.modifierFlags)
        enqueueInput { session in
            try await session.dispatchMouse(
                    type: "mouseWheel",
                    x: x,
                    y: y,
                    button: "none",
                    clickCount: 1,
                    deltaX: deltaX,
                    deltaY: deltaY,
                    modifiers: modifiers
                )
        }
    }

    override func keyDown(with event: NSEvent) {
        sendKey(event, type: "keyDown")
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, type: "keyUp")
    }

    private func sendMouse(
        _ event: NSEvent,
        type: String,
        button: String? = nil,
        clickCount: Int? = nil
    ) {
        let point = pagePoint(for: event)
        let x = Double(point.x)
        let y = Double(point.y)
        let resolvedButton = button ?? (event.buttonNumber == 2 ? "middle" : "left")
        let count = clickCount ?? max(1, event.clickCount)
        let modifiers = ChromiumKeyMapping.modifiers(event.modifierFlags)
        enqueueInput(coalescingKey: type == "mouseMoved" ? "pointer" : nil) { session in
            try await session.dispatchMouse(
                    type: type,
                    x: x,
                    y: y,
                    button: resolvedButton,
                    clickCount: count,
                    modifiers: modifiers
                )
        }
    }

    private func focusForPointerInput() {
        if window?.firstResponder === self {
            onFocus?()
        } else {
            window?.makeFirstResponder(self)
        }
    }

    private func sendKey(_ event: NSEvent, type: String) {
        let mapping = ChromiumKeyMapping.map(event)
        enqueueInput { session in
            try await session.dispatchKey(
                    type: type,
                    key: mapping.key,
                    code: mapping.code,
                    text: type == "keyDown" ? mapping.text : nil,
                    modifiers: mapping.modifiers
                )
        }
    }
}
