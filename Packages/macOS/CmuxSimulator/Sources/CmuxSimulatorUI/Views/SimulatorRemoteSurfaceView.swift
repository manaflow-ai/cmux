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
    var onFrameTransportAdopted: ((SimulatorFrameTransportDescriptor) -> Void)?

    var frameLayer: CALayer?
    private var framePipeline: SimulatorFramePresentationPipeline?
    private var frameTransportDescriptor: SimulatorFrameTransportDescriptor?
    private let frameSourceFactory:
        @MainActor (
            SimulatorFrameTransportDescriptor
        ) throws -> any SimulatorFrameSurfaceReading
    private var presentationTimer: DispatchSourceTimer?
    private var lastFrameSequence: UInt64?
    private var isTornDown = false
    var display: SimulatorDisplayMetadata?
    var chrome: SimulatorDeviceChromeProfile?
    let chromeImageCache = SimulatorDeviceChromeImageCache()
    var input = SimulatorInputStateMachine()
    var chromeButtonInput = SimulatorChromeButtonStateMachine()
    var activeChromeButton: SimulatorDeviceChromeProfile.Button?
    private var hoveredChromeButton: SimulatorDeviceChromeProfile.Button?
    private var mouseTrackingArea: NSTrackingArea?
    var pendingPointerEntry: SimulatorPendingPointerEntry?
    var pendingInputMotion: SimulatorWorkerInbound?
    private var pendingInputFlushTask: Task<Void, Never>?
    var stageHaloPointerActive = false
    var stagePointerMonitor: Any?
    private(set) var isPointerInputEnabled = false
    var pointerEntryEventFilter: (@MainActor (NSEvent) -> Bool)?
    var hostKeyEquivalentHandler: (@MainActor (NSEvent) -> Bool)?
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        frameSourceFactory = { try SimulatorFrameSurfaceSource(descriptor: $0) }
        return nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setPointerInputEnabled(_ enabled: Bool) {
        guard !isTornDown, enabled != isPointerInputEnabled else { return }
        isPointerInputEnabled = enabled
        if enabled, let window {
            installStagePointerMonitor(for: window)
        } else {
            cancelInputs()
            removeStagePointerMonitor()
        }
    }

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
        if self.chrome != chrome {
            chromeImageCache.removeAll()
        }
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
        removeStagePointerMonitor()
        NotificationCenter.default.removeObserver(self)
        stopPresentationTimer()
        retireFramePipeline()
        frameLayer?.removeFromSuperlayer()
        frameLayer = nil
        frameTransportDescriptor = nil
        lastFrameSequence = nil
        display = nil
        chrome = nil
        chromeImageCache.removeAll()
        onMessage = nil
        onGeometry = nil
        onRequestPanelFocus = nil
        pointerEntryEventFilter = nil
        onFrameTransportFailure = nil
        onFrameTransportAdopted = nil
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
        rebuildPresentationTimer()
        pushGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileHostWindowVisibility()
        rebuildPresentationTimer()
        if !isTornDown, isPointerInputEnabled, let window {
            installStagePointerMonitor(for: window)
        } else {
            removeStagePointerMonitor()
        }
        fulfillPendingFocusRequest()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            stopPresentationTimer()
            cancelInputs()
            removeStagePointerMonitor()
            NotificationCenter.default.removeObserver(self)
        }
        super.viewWillMove(toWindow: newWindow)
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
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(hostWindowVisibilityDidChange(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: newWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(hostWindowVisibilityDidChange(_:)),
                name: NSWindow.didMiniaturizeNotification,
                object: newWindow
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(hostWindowVisibilityDidChange(_:)),
                name: NSWindow.didDeminiaturizeNotification,
                object: newWindow
            )
        }
    }

    override func resignFirstResponder() -> Bool {
        cancelInputs()
        return super.resignFirstResponder()
    }

    override func scrollWheel(with event: NSEvent) {
        guard isPointerInputEnabled else { return super.scrollWheel(with: event) }
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
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            let hostHandled = hostKeyEquivalentHandler?(event)
                ?? NSApp.mainMenu?.performKeyEquivalent(with: event)
                ?? false
            if hostHandled { return true }
        }
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
        stopPresentationTimer()
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
        framePipeline = SimulatorFramePresentationPipeline(
            source: source,
            presentationDidComplete: { [weak self] in
                self?.renderLatestFrame()
            }
        )
        frameTransportDescriptor = frameTransport
        onFrameTransportAdopted?(frameTransport)
        renderLatestFrame()
        layoutFrameLayer()
        startPresentationTimer()
    }

    func renderLatestFrame() {
        guard let pipeline = framePipeline,
              let presentation = pipeline.displayTick(),
              presentation.sequence != lastFrameSequence,
              let frameLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = presentation.image
        CATransaction.commit()
        lastFrameSequence = presentation.sequence
    }

    private func startPresentationTimer() {
        guard presentationTimer == nil, let framePipeline else { return }
        guard let window, simulatorHostWindowIsVisible(window) else {
            framePipeline.setFramePublicationNotificationsEnabled(false)
            return
        }
        if framePipeline.setFramePublicationNotificationsEnabled(true) {
            return
        }
        let interval = Self.presentationTimerIntervalNanoseconds(
            maximumFramesPerSecond: window.screen?.maximumFramesPerSecond
        )
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: .nanoseconds(interval),
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.presentationTimerDidFire()
        }
        presentationTimer = timer
        timer.activate()
    }

    static func presentationTimerIntervalNanoseconds(
        maximumFramesPerSecond: Int?
    ) -> Int {
        let framesPerSecond = min(max(maximumFramesPerSecond ?? 60, 1), 120)
        return Int((1_000_000_000 / Double(framesPerSecond)).rounded())
    }

    private func stopPresentationTimer() {
        presentationTimer?.setEventHandler(handler: nil)
        presentationTimer?.cancel()
        presentationTimer = nil
        framePipeline?.setFramePublicationNotificationsEnabled(false)
    }
    private func rebuildPresentationTimer() {
        guard !isTornDown, framePipeline != nil else { return }
        stopPresentationTimer()
        startPresentationTimer()
    }

    private func reconcileHostWindowVisibility() {
        let isVisible = window.map(simulatorHostWindowIsVisible) ?? false
        if isVisible {
            startPresentationTimer()
            renderLatestFrame()
        } else {
            stopPresentationTimer()
        }
    }

    @objc private func hostWindowVisibilityDidChange(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        reconcileHostWindowVisibility()
    }

    private func presentationTimerDidFire() {
        flushPendingInputMotion()
        renderLatestFrame()
    }

    private func retireFramePipeline() {
        let pipeline = framePipeline
        framePipeline = nil
        frameLayer?.contents = nil
        pipeline?.invalidate()
    }

    func normalizedPoint(for event: NSEvent, clamped: Bool = false) -> SimulatorPoint? {
        let location = convert(event.locationInWindow, from: nil)
        return normalizedSimulatorPoint(
            location: location,
            displayRect: displayRect,
            clamped: clamped
        )
    }

    func send(_ messages: [SimulatorWorkerInbound]) {
        for message in messages {
            switch message {
            case let .pointer(event) where event.phase == .moved:
                if case .pointer? = pendingInputMotion {
                    pendingInputMotion = message
                } else {
                    flushPendingInputMotion()
                    pendingInputMotion = message
                }
                schedulePendingInputFlush()
            case let .scrollWheel(event):
                if case let .scrollWheel(pending)? = pendingInputMotion {
                    pendingInputMotion = .scrollWheel(SimulatorScrollWheelEvent(
                        id: pending.id,
                        anchor: pending.anchor,
                        deltaX: min(max(pending.deltaX + event.deltaX, -1), 1),
                        deltaY: min(max(pending.deltaY + event.deltaY, -1), 1)
                    ))
                } else {
                    flushPendingInputMotion()
                    pendingInputMotion = message
                }
                schedulePendingInputFlush()
            default:
                flushPendingInputMotion()
                onMessage?(message)
            }
        }
    }

    func flushPendingInputMotion() {
        pendingInputFlushTask?.cancel()
        pendingInputFlushTask = nil
        guard let pendingInputMotion else { return }
        self.pendingInputMotion = nil
        if case let .scrollWheel(event) = pendingInputMotion,
           event.deltaX == 0, event.deltaY == 0 { return }
        onMessage?(pendingInputMotion)
    }

    private func schedulePendingInputFlush() {
        guard pendingInputFlushTask == nil, pendingInputMotion != nil else { return }
        let interval = Self.presentationTimerIntervalNanoseconds(
            maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond
        )
        pendingInputFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .nanoseconds(Int64(interval)))
            } catch {
                return
            }
            guard let self else { return }
            pendingInputFlushTask = nil
            flushPendingInputMotion()
        }
    }

    private func cancelInputs() {
        pendingInputFlushTask?.cancel()
        pendingInputFlushTask = nil
        pendingInputMotion = nil
        pendingPointerEntry = nil
        stageHaloPointerActive = false
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
