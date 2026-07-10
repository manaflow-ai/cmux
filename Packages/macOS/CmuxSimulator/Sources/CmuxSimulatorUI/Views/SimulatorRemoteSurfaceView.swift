import AppKit
import CmuxSimulator
import Darwin
import ObjectiveC.runtime
import QuartzCore

@MainActor
public protocol SimulatorInputResponder: AnyObject {
    var simulatorOwnerID: ObjectIdentifier? { get }
}

@MainActor
final class SimulatorRemoteSurfaceView: NSView, SimulatorInputResponder {
    var simulatorOwnerID: ObjectIdentifier?
    var onMessage: ((SimulatorWorkerInbound) -> Void)?
    var onGeometry: ((SimulatorSurfaceGeometry) -> Void)?
    var onRequestPanelFocus: (() -> Void)?

    var hostedLayer: CALayer?
    private var hostedContextID: UInt32?
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
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(
        contextID: UInt32,
        display: SimulatorDisplayMetadata,
        chrome: SimulatorDeviceChromeProfile?
    ) {
        let previousGeometry = self.display.map(SimulatorOrientationGeometry.init(display:))
        let geometry = SimulatorOrientationGeometry(display: display)
        if let previousGeometry, previousGeometry != geometry || self.chrome != chrome {
            cancelInputs()
        }
        input.updateOrientationGeometry(geometry)
        self.display = display
        self.chrome = chrome
        updateChromeLayerBackground()
        if contextID != hostedContextID {
            adopt(contextID: contextID)
        }
        needsDisplay = true
        needsLayout = true
    }

    func teardown() {
        cancelInputs()
        NotificationCenter.default.removeObserver(self)
        hostedLayer?.removeFromSuperlayer()
        hostedLayer = nil
        hostedContextID = nil
        onMessage = nil
        onGeometry = nil
        onRequestPanelFocus = nil
        simulatorOwnerID = nil
    }

    override func layout() {
        super.layout()
        layoutHostedLayer()
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
        fulfillPendingFocusRequest()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            cancelInputs()
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
        if let display, let button = chrome?.button(
            at: location,
            in: bounds,
            orientation: display.orientation
        ) {
            activeChromeButton = button
            send(chromeButtonInput.press(button))
            needsDisplay = true
            return
        }
        guard let point = normalizedPoint(for: event) else { return }
        let flags = event.modifierFlags
        send(input.pointerBegan(
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
               ) {
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
            || event.momentumPhase.contains(.changed) {
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
                  modifierFlags: event.modifierFlags
              ) else {
            return super.performKeyEquivalent(with: event)
        }
        if case let .messages(messages) = action { send(messages) }
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
              ) else {
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
        let hovered: SimulatorDeviceChromeProfile.Button? = if let chrome, let display {
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
        onGeometry?(SimulatorSurfaceGeometry(
            width: geometry?.swapsAxes == true ? rect.height : rect.width,
            height: geometry?.swapsAxes == true ? rect.width : rect.height,
            scale: Double(window?.backingScaleFactor ?? 2)
        ))
    }

    private func adopt(contextID: UInt32) {
        hostedLayer?.removeFromSuperlayer()
        hostedLayer = nil
        hostedContextID = nil
        let setter = NSSelectorFromString("setContextId:")
        guard let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type,
              let method = class_getInstanceMethod(hostClass, setter),
              method_getNumberOfArguments(method) == 3,
              let receiverType = method_copyArgumentType(method, 0),
              let selectorType = method_copyArgumentType(method, 1),
              let contextType = method_copyArgumentType(method, 2)
        else {
            return
        }
        let returnType = method_copyReturnType(method)
        defer {
            free(returnType)
            free(receiverType)
            free(selectorType)
            free(contextType)
        }
        guard String(cString: returnType) == "v",
              String(cString: receiverType) == "@",
              String(cString: selectorType) == ":",
              String(cString: contextType) == "I"
        else { return }

        let remoteLayer = hostClass.init()
        typealias Setter = @convention(c) (AnyObject, Selector, UInt32) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(
            remoteLayer,
            setter,
            contextID
        )
        layer?.addSublayer(remoteLayer)
        hostedLayer = remoteLayer
        hostedContextID = contextID
        layoutHostedLayer()
    }

    private func normalizedPoint(for event: NSEvent, clamped: Bool = false) -> SimulatorPoint? {
        let location = convert(event.locationInWindow, from: nil)
        return Self.normalizedPoint(location: location, displayRect: displayRect, clamped: clamped)
    }

    static func normalizedPoint(
        location: CGPoint,
        displayRect rect: CGRect,
        clamped: Bool
    ) -> SimulatorPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        if !clamped, !rect.contains(location) { return nil }
        let x = min(max((location.x - rect.minX) / rect.width, 0), 1)
        let y = min(max(1 - ((location.y - rect.minY) / rect.height), 0), 1)
        return SimulatorPoint(
            x: x,
            y: y
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

    private func drawChrome(
        _ profile: SimulatorDeviceChromeProfile,
        orientation: SimulatorOrientation
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let portraitWidth = profile.portraitWidth
        let portraitHeight = profile.portraitHeight
        let orientedWidth = orientation == .portrait || orientation == .portraitUpsideDown
            ? portraitWidth : portraitHeight
        let orientedHeight = orientation == .portrait || orientation == .portraitUpsideDown
            ? portraitHeight : portraitWidth
        let scale = min(bounds.width / orientedWidth, bounds.height / orientedHeight)
        let origin = CGPoint(
            x: bounds.midX - (orientedWidth * scale / 2),
            y: bounds.midY - (orientedHeight * scale / 2)
        )

        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        switch orientation {
        case .portrait:
            break
        case .portraitUpsideDown:
            context.translateBy(x: portraitWidth, y: portraitHeight)
            context.rotate(by: .pi)
        case .landscapeLeft:
            context.translateBy(x: portraitHeight, y: 0)
            context.rotate(by: .pi / 2)
        case .landscapeRight:
            context.translateBy(x: 0, y: portraitWidth)
            context.rotate(by: -.pi / 2)
        }
        drawPortraitChrome(profile)
        context.restoreGState()
    }

    private func drawPortraitChrome(_ profile: SimulatorDeviceChromeProfile) {
        let body = profile.bodyRect
        drawButtons(profile.buttons.filter { !$0.onTop })
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: body,
            xRadius: profile.cornerRadius,
            yRadius: profile.cornerRadius
        ).fill()

        if let compositeURL = profile.compositeURL,
           let image = NSImage(contentsOf: compositeURL) {
            image.draw(in: body)
        } else {
            let left = profile.bezelInsets.leading
            let right = profile.bezelInsets.trailing
            let top = profile.bezelInsets.top
            let bottom = profile.bezelInsets.bottom
            drawAsset(profile.assets["topLeft"], in: CGRect(x: body.minX, y: body.maxY - top, width: left, height: top))
            drawAsset(profile.assets["top"], in: CGRect(x: body.minX + left, y: body.maxY - top, width: body.width - left - right, height: top))
            drawAsset(profile.assets["topRight"], in: CGRect(x: body.maxX - right, y: body.maxY - top, width: right, height: top))
            drawAsset(profile.assets["right"], in: CGRect(x: body.maxX - right, y: body.minY + bottom, width: right, height: body.height - top - bottom))
            drawAsset(profile.assets["bottomRight"], in: CGRect(x: body.maxX - right, y: body.minY, width: right, height: bottom))
            drawAsset(profile.assets["bottom"], in: CGRect(x: body.minX + left, y: body.minY, width: body.width - left - right, height: bottom))
            drawAsset(profile.assets["bottomLeft"], in: CGRect(x: body.minX, y: body.minY, width: left, height: bottom))
            drawAsset(profile.assets["left"], in: CGRect(x: body.minX, y: body.minY + bottom, width: left, height: body.height - top - bottom))
        }
        drawButtons(profile.buttons.filter(\.onTop))
    }

    private func drawButtons(_ buttons: [SimulatorDeviceChromeProfile.Button]) {
        for button in buttons {
            let isPressed = chromeButtonInput.isHeld(button)
            let isActive = isPressed || hoveredChromeButton == button
            let offset = isActive ? button.rolloverTranslation : SimulatorInputDelta(x: 0, y: 0)
            drawAsset(
                isPressed ? button.imageDownURL ?? button.imageURL : button.imageURL,
                in: CGRect(
                    x: button.rect.x + 4 + offset.x,
                    y: button.rect.y + 4 + offset.y,
                    width: max(button.rect.width - 8, 1),
                    height: max(button.rect.height - 8, 1)
                )
            )
        }
    }

    private func drawAsset(_ url: URL?, in rect: CGRect) {
        guard let url, let image = NSImage(contentsOf: url), rect.width > 0, rect.height > 0 else { return }
        image.draw(in: rect)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        cancelInputs()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        cancelInputs()
    }
}
