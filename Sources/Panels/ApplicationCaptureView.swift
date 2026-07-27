import AppKit
import Carbon.HIToolbox
import CmuxSimulatorUI

@MainActor
final class ApplicationCaptureView: NSView {
    private static let namedKeyCodes: [String: CGKeyCode] = [
        "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B),
        "c": CGKeyCode(kVK_ANSI_C), "d": CGKeyCode(kVK_ANSI_D),
        "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
        "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H),
        "i": CGKeyCode(kVK_ANSI_I), "j": CGKeyCode(kVK_ANSI_J),
        "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
        "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N),
        "o": CGKeyCode(kVK_ANSI_O), "p": CGKeyCode(kVK_ANSI_P),
        "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
        "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T),
        "u": CGKeyCode(kVK_ANSI_U), "v": CGKeyCode(kVK_ANSI_V),
        "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
        "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
        "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1),
        "2": CGKeyCode(kVK_ANSI_2), "3": CGKeyCode(kVK_ANSI_3),
        "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
        "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7),
        "8": CGKeyCode(kVK_ANSI_8), "9": CGKeyCode(kVK_ANSI_9),
        "enter": CGKeyCode(kVK_Return), "return": CGKeyCode(kVK_Return),
        "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
        "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
        "backspace": CGKeyCode(kVK_Delete),
        "delete": CGKeyCode(kVK_ForwardDelete),
        "del": CGKeyCode(kVK_ForwardDelete),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
        "pageup": CGKeyCode(kVK_PageUp), "page_up": CGKeyCode(kVK_PageUp),
        "pagedown": CGKeyCode(kVK_PageDown), "page_down": CGKeyCode(kVK_PageDown),
        "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2),
        "f3": CGKeyCode(kVK_F3), "f4": CGKeyCode(kVK_F4),
        "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
        "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8),
        "f9": CGKeyCode(kVK_F9), "f10": CGKeyCode(kVK_F10),
        "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "down": CGKeyCode(kVK_DownArrow), "up": CGKeyCode(kVK_UpArrow),
    ]

    private let sourceWindowID: UInt32
    private let processID: Int32
    private let targetFrameRate: Int
    private let runtime: any ApplicationSurfaceRuntime
    private let leaseProvider: @MainActor () async -> ApplicationSurfaceRuntimeLease?
    private let onStateChanged: (ApplicationPanel.CaptureState) -> Void
    private let onMovedToWindow: (ApplicationCaptureView) -> Void
    private let remoteFrameView = CmuxRemoteFrameView(frame: .zero)
    private lazy var inputPump = ApplicationSurfaceInputPump { [weak self] event in
        guard
            let self,
            let lease = self.lease,
            let sessionID = self.session?.sessionID
        else {
            return
        }
        do {
            try await self.runtime.sendApplicationSurfaceEvent(
                lease: lease,
                sessionID: sessionID,
                event: event
            )
        } catch ApplicationSurfaceRuntimeError.pointOutsideContent {
            return
        } catch ApplicationSurfaceRuntimeError.windowUnavailable {
            self.handleRuntimeFailure(.windowUnavailable)
        } catch ApplicationSurfaceRuntimeError.permissionRequired {
            self.handleRuntimeFailure(.permissionRequired)
        } catch {
            self.handleRuntimeFailure(.failed)
        }
    }

    private var lease: ApplicationSurfaceRuntimeLease?
    private var session: ApplicationSurfaceSessionDescriptor?
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = UUID()
    private var captureDesired = false
    private var targetUnavailable = false
    private var pendingScrollX = 0.0
    private var pendingScrollY = 0.0
    private var pressedModifierKeyCodes: Set<UInt16> = []
    private var mouseTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(
        windowID: UInt32,
        processID: Int32,
        targetFrameRate: Int,
        runtime: any ApplicationSurfaceRuntime,
        leaseProvider: @escaping @MainActor () async -> ApplicationSurfaceRuntimeLease?,
        onStateChanged: @escaping (ApplicationPanel.CaptureState) -> Void,
        onMovedToWindow: @escaping (ApplicationCaptureView) -> Void
    ) {
        sourceWindowID = windowID
        self.processID = processID
        self.targetFrameRate = targetFrameRate
        self.runtime = runtime
        self.leaseProvider = leaseProvider
        self.onStateChanged = onStateChanged
        self.onMovedToWindow = onMovedToWindow
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(remoteFrameView)
        remoteFrameView.onFirstFrame = { [weak self] in
            guard let self, self.captureDesired, self.session != nil else { return }
            self.onStateChanged(.streaming)
        }
        remoteFrameView.onTransportFailure = { [weak self] error in
            guard let self else { return }
            cmuxDebugLog(
                "applicationSurface.transport.failed"
                    + " window=\(self.sourceWindowID)"
                    + " error=\(error.localizedDescription)"
            )
            self.handleRuntimeFailure(.failed)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            onMovedToWindow(self)
        }
    }

    override func updateTrackingAreas() {
        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        remoteFrameView.frame = bounds
    }

    func setCaptureActive(_ active: Bool) {
        captureDesired = active
        remoteFrameView.setActive(active)
        if active {
            startCapture()
        } else {
            stopCapture()
        }
    }

    func startCapture() {
        guard captureDesired, !targetUnavailable, captureTask == nil, session == nil else {
            return
        }
        let generation = UUID()
        captureGeneration = generation
        onStateChanged(.starting)
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.captureGeneration == generation {
                    self.captureTask = nil
                }
            }
            let lease: ApplicationSurfaceRuntimeLease?
            if let existingLease = self.lease {
                lease = existingLease
            } else {
                lease = await self.leaseProvider()
            }
            guard
                !Task.isCancelled,
                self.captureDesired,
                self.captureGeneration == generation,
                let lease
            else {
                return
            }
            self.lease = lease
            do {
                let session = try await self.runtime.startApplicationSurface(
                    lease: lease,
                    windowID: self.sourceWindowID,
                    processID: self.processID,
                    frameRate: self.targetFrameRate
                )
                guard
                    !Task.isCancelled,
                    self.captureDesired,
                    self.captureGeneration == generation
                else {
                    await self.runtime.stopApplicationSurface(
                        lease: lease,
                        sessionID: session.sessionID
                    )
                    return
                }
                self.session = session
                self.remoteFrameView.adopt(session.frameTransport)
                self.remoteFrameView.setActive(true)
            } catch ApplicationSurfaceRuntimeError.permissionRequired {
                self.onStateChanged(.permissionRequired)
            } catch ApplicationSurfaceRuntimeError.windowUnavailable {
                self.targetUnavailable = true
                self.onStateChanged(.windowUnavailable)
            } catch {
                cmuxDebugLog(
                    "applicationSurface.start.failed"
                        + " window=\(self.sourceWindowID)"
                        + " error=\(error.localizedDescription)"
                )
                self.onStateChanged(.failed)
            }
        }
    }

    func stopCapture() {
        captureDesired = false
        captureGeneration = UUID()
        captureTask?.cancel()
        captureTask = nil
        remoteFrameView.setActive(false)
        inputPump.cancelPending()
        pendingScrollX = 0
        pendingScrollY = 0
        pressedModifierKeyCodes.removeAll()
        guard let session, let lease else {
            self.session = nil
            return
        }
        self.session = nil
        Task { @MainActor [runtime] in
            await runtime.stopApplicationSurface(
                lease: lease,
                sessionID: session.sessionID
            )
        }
    }

    func teardown() {
        stopCapture()
        remoteFrameView.teardown()
        lease = nil
    }

    func sendNamedKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> Bool {
        guard captureDesired, session != nil, lease != nil else { return false }
        inputPump.enqueue(ApplicationSurfaceInputEvent(
            kind: .key,
            keyCode: keyCode,
            keyDown: true,
            modifiers: flags.rawValue
        ))
        inputPump.enqueue(ApplicationSurfaceInputEvent(
            kind: .key,
            keyCode: keyCode,
            keyDown: false,
            modifiers: flags.rawValue
        ))
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        enqueueMouse(event, kind: .leftMouseDown)
    }

    override func mouseUp(with event: NSEvent) {
        enqueueMouse(event, kind: .leftMouseUp)
    }

    override func rightMouseDown(with event: NSEvent) {
        enqueueMouse(event, kind: .rightMouseDown)
    }

    override func rightMouseUp(with event: NSEvent) {
        enqueueMouse(event, kind: .rightMouseUp)
    }

    override func mouseMoved(with event: NSEvent) {
        enqueueMouse(event, kind: .mouseMoved)
    }

    override func mouseDragged(with event: NSEvent) {
        enqueueMouse(event, kind: .leftMouseDragged)
    }

    override func rightMouseDragged(with event: NSEvent) {
        enqueueMouse(event, kind: .rightMouseDragged)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = normalizedPoint(for: event) else { return }
        pendingScrollX += event.scrollingDeltaX
        pendingScrollY += event.scrollingDeltaY
        let scrollX = pendingScrollX.rounded(.towardZero)
        let scrollY = pendingScrollY.rounded(.towardZero)
        pendingScrollX -= scrollX
        pendingScrollY -= scrollY
        guard scrollX != 0 || scrollY != 0 else { return }
        inputPump.enqueue(ApplicationSurfaceInputEvent(
            kind: .scroll,
            x: point.x,
            y: point.y,
            modifiers: UInt64(event.modifierFlags.rawValue),
            deltaX: scrollX,
            deltaY: scrollY
        ))
    }

    override func keyDown(with event: NSEvent) {
        enqueueKey(event, keyDown: true)
    }

    override func keyUp(with event: NSEvent) {
        enqueueKey(event, keyDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Command, kVK_RightCommand,
             kVK_Shift, kVK_RightShift,
             kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl,
             kVK_CapsLock, kVK_Function:
            break
        default:
            return
        }
        let keyDown = Self.modifierKeyTransition(
            keyCode: event.keyCode,
            pressedKeyCodes: &pressedModifierKeyCodes
        )
        enqueueKey(event, keyDown: keyDown)
    }

    private func enqueueMouse(_ event: NSEvent, kind: ApplicationSurfaceInputEvent.Kind) {
        guard let point = normalizedPoint(for: event) else { return }
        inputPump.enqueue(ApplicationSurfaceInputEvent(
            kind: kind,
            x: point.x,
            y: point.y,
            modifiers: UInt64(event.modifierFlags.rawValue),
            clickCount: event.clickCount
        ))
    }

    private func enqueueKey(_ event: NSEvent, keyDown: Bool) {
        guard captureDesired, session != nil, lease != nil else { return }
        inputPump.enqueue(ApplicationSurfaceInputEvent(
            kind: .key,
            keyCode: event.keyCode,
            keyDown: keyDown,
            modifiers: UInt64(event.modifierFlags.rawValue)
        ))
    }

    private func normalizedPoint(for event: NSEvent) -> CGPoint? {
        guard captureDesired, session != nil, lease != nil else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let frameSize = remoteFrameView.framePixelSize
        guard
            let source = Self.sourcePoint(
                for: point,
                in: bounds,
                sourceFrame: CGRect(origin: .zero, size: frameSize)
            ),
            frameSize.width > 0,
            frameSize.height > 0
        else {
            return nil
        }
        return CGPoint(
            x: source.x / frameSize.width,
            y: source.y / frameSize.height
        )
    }

    private func handleRuntimeFailure(_ state: ApplicationPanel.CaptureState) {
        guard captureDesired else { return }
        if state == .windowUnavailable {
            targetUnavailable = true
        }
        onStateChanged(state)
        stopCapture()
    }

    static func parseNamedKey(_ name: String) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        let normalized = name
            .lowercased()
            .replacingOccurrences(of: "+", with: "-")
        var components = normalized.split(separator: "-").map(String.init)
        guard
            let keyName = components.popLast(),
            let keyCode = namedKeyCodes[keyName]
        else {
            return nil
        }
        var flags: CGEventFlags = []
        for modifier in components {
            switch modifier {
            case "ctrl", "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "cmd", "command", "super": flags.insert(.maskCommand)
            default: return nil
            }
        }
        return (keyCode, flags)
    }

    static func modifierKeyTransition(
        keyCode: UInt16,
        pressedKeyCodes: inout Set<UInt16>
    ) -> Bool {
        if pressedKeyCodes.remove(keyCode) != nil {
            return false
        }
        pressedKeyCodes.insert(keyCode)
        return true
    }

    static func sourcePoint(
        for point: CGPoint,
        in bounds: CGRect,
        sourceFrame: CGRect
    ) -> CGPoint? {
        guard
            bounds.width > 0,
            bounds.height > 0,
            sourceFrame.width > 0,
            sourceFrame.height > 0
        else {
            return nil
        }
        let scale = min(
            bounds.width / sourceFrame.width,
            bounds.height / sourceFrame.height
        )
        guard scale > 0 else { return nil }
        let renderedSize = CGSize(
            width: sourceFrame.width * scale,
            height: sourceFrame.height * scale
        )
        let renderedRect = CGRect(
            x: (bounds.width - renderedSize.width) / 2,
            y: (bounds.height - renderedSize.height) / 2,
            width: renderedSize.width,
            height: renderedSize.height
        )
        guard renderedRect.contains(point) else { return nil }
        return CGPoint(
            x: sourceFrame.minX + (point.x - renderedRect.minX) / scale,
            y: sourceFrame.minY + (point.y - renderedRect.minY) / scale
        )
    }

}

@MainActor
private final class ApplicationSurfaceInputPump {
    typealias Sender = @MainActor (ApplicationSurfaceInputEvent) async -> Void

    private let sender: Sender
    private var queue: [ApplicationSurfaceInputEvent] = []
    private var drainTask: Task<Void, Never>?
    private var generation = UUID()

    init(sender: @escaping Sender) {
        self.sender = sender
    }

    func enqueue(_ event: ApplicationSurfaceInputEvent) {
        if event.kind.isCoalescibleMotion,
           let lastIndex = queue.indices.last,
           queue[lastIndex].kind.isCoalescibleMotion {
            queue[lastIndex] = event
        } else {
            queue.append(event)
        }
        if queue.count > 64 {
            queue.removeAll(where: { $0.kind.isCoalescibleMotion })
        }
        startDrainIfNeeded()
    }

    func cancelPending() {
        generation = UUID()
        drainTask?.cancel()
        drainTask = nil
        queue.removeAll()
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        let generation = generation
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.generation == generation, !self.queue.isEmpty {
                let event = self.queue.removeFirst()
                await self.sender(event)
            }
            if self.generation == generation {
                self.drainTask = nil
                if !self.queue.isEmpty {
                    self.startDrainIfNeeded()
                }
            }
        }
    }
}
