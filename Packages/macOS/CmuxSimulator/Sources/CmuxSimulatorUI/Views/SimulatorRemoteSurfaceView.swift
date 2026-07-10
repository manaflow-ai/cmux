import AppKit
import CmuxSimulator
import QuartzCore

@MainActor
final class SimulatorRemoteSurfaceView: NSView, SimulatorInputResponder {
    var simulatorOwnerID: ObjectIdentifier?
    var onMessage: ((SimulatorWorkerInbound) -> Void)?
    var onGeometry: ((SimulatorSurfaceGeometry) -> Void)?
    var onRequestPanelFocus: (() -> Void)?
    var onFrameTransportFailure: ((SimulatorFrameTransportDescriptor, SimulatorFailure) -> Void)?

    var frameLayer: CALayer?
    private var framePipeline: SimulatorFramePresentationPipeline?
    private var frameTransportDescriptor: SimulatorFrameTransportDescriptor?
    private let frameSourceFactory:
        @MainActor (
            SimulatorFrameTransportDescriptor
        ) throws -> any SimulatorFrameSurfaceReading
    private var displayLink: CADisplayLink?
    private var frameTickTask: Task<Void, Never>?
    private var frameGeneration: UInt64 = 0
    private var screenObserver: NSObjectProtocol?
    private var lastFrameSequence: UInt64?
    private var isTornDown = false
    var display: SimulatorDisplayMetadata?
    var chrome: SimulatorDeviceChromeProfile?
    private var input = SimulatorInputStateMachine()
    private var chromeButtonInput = SimulatorChromeButtonStateMachine()
    private var activeChromeButton: SimulatorDeviceChromeProfile.Button?
    private var hoveredChromeButton: SimulatorDeviceChromeProfile.Button?
    private var mouseTrackingArea: NSTrackingArea?
    var handledFocusGeneration: UInt64 = 0
    var pendingFocusGeneration: UInt64?

    override init(frame frameRect: NSRect) {
        frameSourceFactory = { try SimulatorFrameSurfaceSource(descriptor: $0) }
        super.init(frame: frameRect)
        configureLayerBacking()
    }

    init(
        frameSourceFactory:
            @escaping @MainActor (
                SimulatorFrameTransportDescriptor
            ) throws -> any SimulatorFrameSurfaceReading
    ) {
        self.frameSourceFactory = frameSourceFactory
        super.init(frame: .zero)
        configureLayerBacking()
    }

    private func configureLayerBacking() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildDisplayLink()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        frameSourceFactory = { try SimulatorFrameSurfaceSource(descriptor: $0) }
        return nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(
        frameTransport: SimulatorFrameTransportDescriptor,
        display: SimulatorDisplayMetadata,
        chrome: SimulatorDeviceChromeProfile?
    ) {
        guard !isTornDown else { return }
        let previousGeometry = self.display.map(SimulatorOrientationGeometry.init(display:))
        let geometry = SimulatorOrientationGeometry(display: display)
        if let previousGeometry, previousGeometry != geometry || self.chrome != chrome {
            cancelInputs()
        }
        input.updateOrientationGeometry(geometry)
        self.display = display
        self.chrome = chrome
        updateChromeLayerBackground()
        if frameTransport != frameTransportDescriptor {
            adopt(frameTransport: frameTransport)
        }
        needsDisplay = true
        needsLayout = true
    }

    func teardown() {
        isTornDown = true
        cancelInputs()
        NotificationCenter.default.removeObserver(self)
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        stopDisplayLink()
        retireFramePipeline()
        frameLayer?.removeFromSuperlayer()
        frameLayer = nil
        frameTransportDescriptor = nil
        lastFrameSequence = nil
        display = nil
        chrome = nil
        onMessage = nil
        onGeometry = nil
        onRequestPanelFocus = nil
        onFrameTransportFailure = nil
        simulatorOwnerID = nil
    }

    override func layout() {
        super.layout()
        layoutFrameLayer()
        pushGeometry()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        guard let chrome, let display else {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 34, yRadius: 34).fill()
            return
        }
        drawChrome(chrome, orientation: display.orientation)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        pushGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildDisplayLink()
        fulfillPendingFocusRequest()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        let isBeingRemoved = window != nil && newWindow == nil
        if window !== newWindow {
            cancelInputs()
            NotificationCenter.default.removeObserver(self)
        }
        super.viewWillMove(toWindow: newWindow)
        if isBeingRemoved {
            teardown()
            return
        }
        if let newWindow {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: newWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: newWindow
            )
        }
    }

    override func resignFirstResponder() -> Bool {
        cancelInputs()
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        onRequestPanelFocus?()
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        if let display,
            let button = chrome?.button(
                at: location,
                in: bounds,
                orientation: display.orientation
            )
        {
            activeChromeButton = button
            send(chromeButtonInput.press(button))
            needsDisplay = true
            return
        }
        guard let point = normalizedPoint(for: event) else { return }
        let flags = event.modifierFlags
        send(
            input.pointerBegan(
                at: point,
                optionPinch: flags.contains(.option),
                parallelPan: flags.contains(.shift)
            ))
    }

    override func mouseDragged(with event: NSEvent) {
        if let button = activeChromeButton {
            let location = convert(event.locationInWindow, from: nil)
            if let chrome, let display,
                !chrome.contains(
                    location,
                    button: button,
                    in: bounds,
                    orientation: display.orientation
                )
            {
                send(chromeButtonInput.release(button))
                activeChromeButton = nil
                needsDisplay = true
            }
            return
        }
        guard let point = normalizedPoint(for: event, clamped: true) else { return }
        send(input.pointerMoved(to: point))
    }

    override func mouseUp(with event: NSEvent) {
        if let button = activeChromeButton {
            send(chromeButtonInput.release(button))
            activeChromeButton = nil
            needsDisplay = true
            return
        }
        let point = normalizedPoint(for: event, clamped: true) ?? input.activePointer
        guard let point else { return }
        send(input.pointerEnded(at: point))
    }

    override func scrollWheel(with event: NSEvent) {
        let phase: SimulatorInputStateMachine.ScrollPhase
        if event.phase.contains(.began) {
            phase = .began
        } else if event.phase.contains(.changed) || event.momentumPhase.contains(.began)
            || event.momentumPhase.contains(.changed)
        {
            phase = .changed
        } else if event.phase.contains(.cancelled) || event.momentumPhase.contains(.cancelled) {
            phase = .cancelled
        } else if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
            phase = .ended
        } else {
            phase = .discrete
        }
        let messages = input.scroll(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            phase: phase,
            anchor: normalizedPoint(for: event, clamped: true) ?? SimulatorPoint(x: 0.5, y: 0.5)
        )
        guard !messages.isEmpty else { return super.scrollWheel(with: event) }
        send(messages)
    }
    override func keyDown(with event: NSEvent) {
        guard let usage = simulatorHIDKeyMapper.usage(for: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        send(input.key(usage: usage, phase: .down))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
            let action = simulatorKeyEquivalentTranslator.action(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                heldUsages: input.heldKeys
            )
        else {
            return super.performKeyEquivalent(with: event)
        }
        if case .messages(let messages) = action { send(messages) }
        return true
    }

    override func keyUp(with event: NSEvent) {
        guard let usage = simulatorHIDKeyMapper.usage(for: event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        send(input.key(usage: usage, phase: .up))
    }

    override func flagsChanged(with event: NSEvent) {
        guard let usage = simulatorHIDKeyMapper.usage(for: event.keyCode),
            let isDown = simulatorHIDKeyMapper.modifierIsDown(
                for: event.keyCode,
                flags: event.modifierFlags
            )
        else {
            super.flagsChanged(with: event)
            return
        }
        send(input.key(usage: usage, phase: isDown ? .down : .up))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let hovered: SimulatorDeviceChromeProfile.Button? =
            if let chrome, let display {
                chrome.button(at: location, in: bounds, orientation: display.orientation)
            } else {
                nil
            }
        guard hovered != hoveredChromeButton else { return }
        hoveredChromeButton = hovered
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredChromeButton != nil else { return }
        hoveredChromeButton = nil
        needsDisplay = true
    }

    private func pushGeometry() {
        let rect = displayRect
        guard rect.width > 0, rect.height > 0 else { return }
        let geometry = orientationGeometry
        onGeometry?(
            SimulatorSurfaceGeometry(
                width: geometry?.swapsAxes == true ? rect.height : rect.width,
                height: geometry?.swapsAxes == true ? rect.width : rect.height,
                scale: Double(window?.backingScaleFactor ?? 2)
            ))
    }

    private func adopt(frameTransport: SimulatorFrameTransportDescriptor) {
        guard !isTornDown else { return }
        let source: any SimulatorFrameSurfaceReading
        do {
            source = try frameSourceFactory(frameTransport)
        } catch {
            onFrameTransportFailure?(
                frameTransport,
                SimulatorFailure(
                    code: "framebuffer_unavailable",
                    message: error.localizedDescription,
                    isRecoverable: true
                )
            )
            return
        }
        stopDisplayLink()
        retireFramePipeline()
        frameLayer?.removeFromSuperlayer()
        frameLayer = nil
        frameTransportDescriptor = nil
        lastFrameSequence = nil
        let frameLayer = CALayer()
        frameLayer.contentsGravity = .resize
        frameLayer.minificationFilter = .linear
        frameLayer.magnificationFilter = .linear
        layer?.addSublayer(frameLayer)
        self.frameLayer = frameLayer
        framePipeline = SimulatorFramePresentationPipeline(source: source)
        frameTransportDescriptor = frameTransport
        renderLatestFrame()
        layoutFrameLayer()
        startDisplayLink()
    }

    func renderLatestFrame() {
        guard frameTickTask == nil,
              let pipeline = framePipeline else { return }
        let generation = frameGeneration
        frameTickTask = Task { @MainActor [weak self] in
            let presentation = await pipeline.displayTick()
            guard let self else { return }
            defer {
                if self.frameGeneration == generation {
                    self.frameTickTask = nil
                }
            }
            guard !Task.isCancelled,
                  self.frameGeneration == generation,
                  self.framePipeline === pipeline,
                  let presentation,
                  presentation.sequence != self.lastFrameSequence,
                  let frameLayer = self.frameLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            frameLayer.contents = presentation.image
            CATransaction.commit()
            self.lastFrameSequence = presentation.sequence
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil,
            framePipeline != nil,
            let window,
            let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let link = screen.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
    private func rebuildDisplayLink() {
        guard !isTornDown, framePipeline != nil else { return }
        stopDisplayLink()
        startDisplayLink()
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        renderLatestFrame()
    }

    private func retireFramePipeline() {
        frameGeneration &+= 1
        frameTickTask?.cancel()
        frameTickTask = nil
        let pipeline = framePipeline
        framePipeline = nil
        frameLayer?.contents = nil
        if let pipeline {
            Task { await pipeline.invalidate() }
        }
    }

    private func normalizedPoint(for event: NSEvent, clamped: Bool = false) -> SimulatorPoint? {
        let location = convert(event.locationInWindow, from: nil)
        return normalizedSimulatorPoint(
            location: location,
            displayRect: displayRect,
            clamped: clamped
        )
    }

    private func send(_ messages: [SimulatorWorkerInbound]) {
        for message in messages { onMessage?(message) }
    }

    private func cancelInputs() {
        send(chromeButtonInput.releaseAll())
        activeChromeButton = nil
        hoveredChromeButton = nil
        send(input.releaseAll())
        needsDisplay = true
    }

    func chromeButtonIsPressed(_ button: SimulatorDeviceChromeProfile.Button) -> Bool {
        chromeButtonInput.isHeld(button)
    }

    func chromeButtonIsHovered(_ button: SimulatorDeviceChromeProfile.Button) -> Bool {
        hoveredChromeButton == button
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        cancelInputs()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        cancelInputs()
    }
}

func normalizedSimulatorPoint(
    location: CGPoint,
    displayRect rect: CGRect,
    clamped: Bool
) -> SimulatorPoint? {
    guard rect.width > 0, rect.height > 0 else { return nil }
    if !clamped, !rect.contains(location) { return nil }
    let x = min(max((location.x - rect.minX) / rect.width, 0), 1)
    let y = min(max(1 - ((location.y - rect.minY) / rect.height), 0), 1)
    return SimulatorPoint(x: x, y: y)
}
