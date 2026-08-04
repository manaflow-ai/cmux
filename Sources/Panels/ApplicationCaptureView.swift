import AppKit
import Carbon.HIToolbox
import CmuxSimulatorUI

nonisolated struct ApplicationCaptureActivity: Equatable, Sendable {
    let paneWantsCapture: Bool
    let hostAttached: Bool
    let hostVisible: Bool

    var ownsSession: Bool {
        paneWantsCapture && hostAttached
    }

    var acceptsInput: Bool {
        ownsSession && hostVisible
    }
}

@MainActor
final class ApplicationCaptureView: NSView {
    private static let firstFrameTimeout: TimeInterval = 8
    private static let maximumInputReleaseAttemptCount = 2

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
    private let onStateChanged: (ApplicationCaptureState, String?) -> Void
    private let onMovedToWindow: (ApplicationCaptureView) -> Void
    private let onPointerDown: () -> Void
    private let onRepresentableDismantled: (ApplicationCaptureView, UUID) -> Void
    private let commandEquivalentRoutingPolicy: ApplicationCommandEquivalentRoutingPolicy
    private let modifierFlagsRawValueProvider: () -> UInt
    private let remoteFrameView = CmuxRemoteFrameView(frame: .zero)
    private lazy var inputPump = ApplicationSurfaceInputPump { [weak self] events in
        guard
            let self,
            let lease = self.lease,
            let sessionID = self.session?.sessionID
        else {
            return false
        }
        do {
            try await self.runtime.sendApplicationSurfaceEvents(
                lease: lease,
                sessionID: sessionID,
                events: events
            )
            return true
        } catch ApplicationSurfaceRuntimeError.pointOutsideContent {
            return false
        } catch ApplicationSurfaceRuntimeError.captureUnavailable {
            return false
        } catch ApplicationSurfaceRuntimeError.windowUnavailable {
            self.handleRuntimeFailure(
                .windowUnavailable,
                failureDetail: ApplicationSurfaceRuntimeError
                    .windowUnavailable.localizedDescription
            )
        } catch ApplicationSurfaceRuntimeError.permissionRequired {
            self.handleRuntimeFailure(
                .permissionRequired,
                failureDetail: ApplicationSurfaceRuntimeError
                    .permissionRequired.localizedDescription
            )
        } catch {
            self.handleRuntimeFailure(
                .failed,
                failureDetail: error.localizedDescription
            )
        }
        return false
    }

    private var lease: ApplicationSurfaceRuntimeLease?
    private var session: ApplicationSurfaceSessionDescriptor?
    private var captureTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var inputReleaseTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var runtimeFailureTask: Task<Void, Never>?
    private var livenessState: ApplicationCaptureLivenessState?
    private var captureGeneration = UUID()
    private var attachmentAcknowledged = false
    private var firstFramePresented = false
    private var captureReadinessPublished = false
    private var inputReleaseGeneration = UUID()
    private var captureDesired = false
    private var hostWindowAttached = false
    private var hostWindowVisible = false
    private var hasInputOwnership = false
    private var targetUnavailable = false
    private var pendingScrollX = 0.0
    private var pendingScrollY = 0.0
    private var pressedModifierKeyCodes: Set<UInt16> = []
    private var currentModifierKeyCodes: Set<UInt16> = []
    private var lastEnqueuedLeftMousePoint: CGPoint?
    private var lastEnqueuedRightMousePoint: CGPoint?
    private var mouseTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    var isReleasingForwardedInput: Bool { inputReleaseTask != nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        hasInputOwnership && PaneFirstClickFocusSettings.isEnabled()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        guard accepted else { return false }
        if let currentEvent = NSApp.currentEvent,
           currentEvent.window === window {
            currentModifierKeyCodes = Self.modifierKeyCodes(
                modifierFlagsRawValue: currentEvent.modifierFlags.rawValue
            )
        } else {
            refreshPhysicalModifierKeys()
        }
        if window?.isKeyWindow == true {
            synchronizeForwardedModifierKeys()
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        guard resigned else { return false }
        currentModifierKeyCodes.removeAll()
        releaseForwardedInputs()
        return true
    }

    init(
        windowID: UInt32,
        processID: Int32,
        targetFrameRate: Int,
        runtime: any ApplicationSurfaceRuntime,
        leaseProvider: @escaping @MainActor () async -> ApplicationSurfaceRuntimeLease?,
        onStateChanged: @escaping (ApplicationCaptureState, String?) -> Void,
        onMovedToWindow: @escaping (ApplicationCaptureView) -> Void,
        onPointerDown: @escaping () -> Void = {},
        onRepresentableDismantled:
            @escaping (ApplicationCaptureView, UUID) -> Void = { _, _ in },
        commandEquivalentRoutingPolicy: ApplicationCommandEquivalentRoutingPolicy = .init(),
        modifierFlagsRawValueProvider: @escaping () -> UInt = {
            NSEvent.modifierFlags.rawValue
        }
    ) {
        sourceWindowID = windowID
        self.processID = processID
        self.targetFrameRate = targetFrameRate
        self.runtime = runtime
        self.leaseProvider = leaseProvider
        self.onStateChanged = onStateChanged
        self.onMovedToWindow = onMovedToWindow
        self.onPointerDown = onPointerDown
        self.onRepresentableDismantled = onRepresentableDismantled
        self.commandEquivalentRoutingPolicy = commandEquivalentRoutingPolicy
        self.modifierFlagsRawValueProvider = modifierFlagsRawValueProvider
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(remoteFrameView)
        remoteFrameView.onFirstFrame = { [weak self] in
            guard let self, self.shouldCaptureNow, self.session != nil else { return }
            self.firstFramePresented = true
            self.publishCaptureReadinessIfReady()
        }
        remoteFrameView.onFramePresented = { [weak self] in
            self?.recordPresentedFrame()
        }
        remoteFrameView.onHostVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.hostWindowVisible = visible
            if visible {
                self.refreshPhysicalModifierKeysAndSynchronizeIfFocused()
                if self.shouldCaptureNow,
                   self.session != nil,
                   !self.firstFramePresented,
                   self.livenessTask == nil {
                    self.beginLivenessWatchdog(
                        generation: self.captureGeneration
                    )
                }
            } else {
                self.stopLivenessWatchdog()
                self.releaseForwardedInputs()
            }
        }
        remoteFrameView.onTransportFailure = { [weak self] failure in
            guard let self else { return }
            cmuxDebugLog(
                "applicationSurface.transport.failed"
                    + " window=\(self.sourceWindowID)"
                    + " failure=\(String(describing: failure))"
            )
            self.handleRuntimeFailure(
                .failed,
                failureDetail: Self.localizedTransportFailureDetail(failure)
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            if window != nil {
                releaseForwardedInputs()
            }
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }
        super.viewWillMove(toWindow: newWindow)
        guard let newWindow else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostWindowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: newWindow
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: newWindow
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hostWindowAttached = window != nil
        reconcileCaptureActivity()
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
        reconcileCaptureActivity()
    }

    func setInputOwnership(_ ownsInput: Bool) {
        guard hasInputOwnership != ownsInput else { return }
        hasInputOwnership = ownsInput
        if ownsInput {
            refreshPhysicalModifierKeysAndSynchronizeIfFocused()
        } else {
            releaseForwardedInputs()
        }
    }

    func representableWasDismantled(mountID: UUID) {
        onRepresentableDismantled(self, mountID)
    }

    func startCapture() {
        guard
            shouldCaptureNow,
            !targetUnavailable,
            captureTask == nil,
            stopTask == nil,
            inputReleaseTask == nil,
            session == nil
        else {
            return
        }
        let generation = UUID()
        captureGeneration = generation
        attachmentAcknowledged = false
        firstFramePresented = false
        captureReadinessPublished = false
        onStateChanged(.starting, nil)
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.captureTask = nil
                if self.shouldCaptureNow {
                    self.startCapture()
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
                self.shouldCaptureNow,
                self.captureGeneration == generation
            else {
                return
            }
            guard let lease else {
                self.captureDesired = false
                self.remoteFrameView.setActive(false)
                self.onStateChanged(
                    .failed,
                    ApplicationSurfaceRuntimeError
                        .helperUnavailable.localizedDescription
                )
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
                    self.shouldCaptureNow,
                    self.captureGeneration == generation
                else {
                    await self.runtime.stopApplicationSurface(
                        lease: lease,
                        sessionID: session.sessionID
                    )
                    return
                }
                self.session = session
                self.beginRuntimeFailureObservation(
                    lease: lease,
                    session: session,
                    generation: generation
                )
                self.beginLivenessWatchdog(generation: generation)
                guard self.remoteFrameView.adopt(
                    session.frameTransport,
                    maximumFramesPerSecond:
                        session.maximumPresentationFramesPerSecond
                ) else {
                    return
                }
                do {
                    try await self.runtime
                        .acknowledgeApplicationSurfaceAttachment(
                            lease: lease,
                            sessionID: session.sessionID
                        )
                } catch {
                    guard
                        !Task.isCancelled,
                        self.shouldCaptureNow,
                        self.captureGeneration == generation,
                        self.session?.sessionID == session.sessionID
                    else {
                        return
                    }
                    self.handleRuntimeFailure(
                        .failed,
                        failureDetail: error.localizedDescription
                    )
                    return
                }
                guard
                    self.shouldCaptureNow,
                    self.captureGeneration == generation,
                    self.session?.sessionID == session.sessionID
                else {
                    return
                }
                self.attachmentAcknowledged = true
                self.remoteFrameView.setActive(true)
                self.publishCaptureReadinessIfReady()
            } catch ApplicationSurfaceRuntimeError.permissionRequired {
                guard
                    !Task.isCancelled,
                    self.shouldCaptureNow,
                    self.captureGeneration == generation
                else {
                    return
                }
                self.captureDesired = false
                self.remoteFrameView.setActive(false)
                self.onStateChanged(
                    .permissionRequired,
                    ApplicationSurfaceRuntimeError
                        .permissionRequired.localizedDescription
                )
            } catch ApplicationSurfaceRuntimeError.windowUnavailable {
                guard
                    !Task.isCancelled,
                    self.shouldCaptureNow,
                    self.captureGeneration == generation
                else {
                    return
                }
                self.captureDesired = false
                self.targetUnavailable = true
                self.remoteFrameView.setActive(false)
                self.onStateChanged(
                    .windowUnavailable,
                    ApplicationSurfaceRuntimeError
                        .windowUnavailable.localizedDescription
                )
            } catch {
                guard
                    !Task.isCancelled,
                    self.shouldCaptureNow,
                    self.captureGeneration == generation
                else {
                    return
                }
                self.captureDesired = false
                self.remoteFrameView.setActive(false)
                cmuxDebugLog(
                    "applicationSurface.start.failed"
                        + " window=\(self.sourceWindowID)"
                        + " error=\(error.localizedDescription)"
                )
                self.onStateChanged(.failed, error.localizedDescription)
            }
        }
    }

    func stopCapture() {
        captureDesired = false
        suspendCapture(reportState: false)
    }

    private func suspendCapture(reportState: Bool) {
        captureGeneration = UUID()
        attachmentAcknowledged = false
        firstFramePresented = false
        captureReadinessPublished = false
        captureTask?.cancel()
        runtimeFailureTask?.cancel()
        runtimeFailureTask = nil
        stopLivenessWatchdog()
        remoteFrameView.setActive(false)
        remoteFrameView.resetTransport()
        if reportState {
            onStateChanged(.suspended, nil)
        }
        pendingScrollX = 0
        pendingScrollY = 0
        pressedModifierKeyCodes.removeAll()
        currentModifierKeyCodes.removeAll()
        lastEnqueuedLeftMousePoint = nil
        lastEnqueuedRightMousePoint = nil
        guard stopTask == nil else { return }
        let session = session
        let lease = lease
        guard session != nil else { return }
        let inputReleaseTask = beginInputRelease(session: session, lease: lease)
        self.session = nil
        let runtime = runtime
        let inputPump = inputPump
        stopTask = Task { @MainActor [weak self] in
            await inputReleaseTask.value
            if let session, let lease {
                await runtime.stopApplicationSurface(
                    lease: lease,
                    sessionID: session.sessionID
                )
                inputPump.resetAfterSessionStop()
            }
            guard let self else { return }
            self.stopTask = nil
            if self.shouldCaptureNow {
                self.startCapture()
            }
        }
    }

    func teardown() {
        stopCapture()
        NotificationCenter.default.removeObserver(self)
        remoteFrameView.teardown()
        lease = nil
    }

    func releaseForwardedInputs() {
        _ = beginInputRelease(session: session, lease: lease)
    }

    func waitUntilForwardedInputReleased() async {
        while let inputReleaseTask {
            await inputReleaseTask.value
        }
    }

    func sendNamedKey(
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> ApplicationNamedKeySendResult {
        guard canForwardInput else {
            return .surfaceUnavailable
        }
        switch enqueueBalancedKeyPress(
            keyCode: keyCode,
            modifiers: flags.rawValue
        ) {
        case .accepted:
            return .queued
        case .full:
            return .inputQueueFull
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard hasInputOwnership else { return }
        onPointerDown()
        window?.makeFirstResponder(self)
        enqueueMouse(event, kind: .leftMouseDown)
    }

    override func mouseUp(with event: NSEvent) {
        enqueueMouse(event, kind: .leftMouseUp)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard hasInputOwnership else { return }
        onPointerDown()
        window?.makeFirstResponder(self)
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
        guard inputPump.enqueue(ApplicationSurfaceInputEvent(
            kind: .scroll,
            frameSequence: remoteFrameView.presentedFrameSequence ?? 0,
            x: point.x,
            y: point.y,
            modifiers: UInt64(event.modifierFlags.rawValue),
            deltaX: scrollX,
            deltaY: scrollY
        )) == .accepted else {
            handleInputQueueFull()
            return
        }
    }

    override func keyDown(with event: NSEvent) {
        enqueueKey(event, keyDown: true)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard shouldRouteCommandEquivalentThroughContentFirst(event)
        else {
            return super.performKeyEquivalent(with: event)
        }
        guard canForwardInput else { return false }
        switch enqueueBalancedKeyPress(
            keyCode: event.keyCode,
            modifiers: UInt64(event.modifierFlags.rawValue)
        ) {
        case .accepted:
            return true
        case .full:
            handleInputQueueFull()
            return false
        }
    }

    func shouldRouteCommandEquivalentThroughContentFirst(
        _ event: NSEvent
    ) -> Bool {
        commandEquivalentRoutingPolicy.shouldRouteThroughContentFirst(event)
    }

    func performKeyEquivalent(
        with event: NSEvent,
        fallback: () -> Bool
    ) -> Bool {
        if performKeyEquivalent(with: event) {
            return true
        }
        return fallback()
    }

    override func keyUp(with event: NSEvent) {
        enqueueKey(event, keyDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard hasInputOwnership else { return }
        guard let keyDown = Self.modifierKeyIsDown(
            keyCode: event.keyCode,
            modifierFlagsRawValue: event.modifierFlags.rawValue
        ) else {
            return
        }
        if keyDown {
            currentModifierKeyCodes.insert(event.keyCode)
        } else {
            currentModifierKeyCodes.remove(event.keyCode)
        }
        guard enqueueKey(event, keyDown: keyDown) else { return }
        if keyDown {
            pressedModifierKeyCodes.insert(event.keyCode)
        } else {
            pressedModifierKeyCodes.remove(event.keyCode)
        }
    }

    private func enqueueMouse(_ event: NSEvent, kind: ApplicationSurfaceInputEventKind) {
        let normalizedPoint = normalizedPoint(for: event)
        guard let point = Self.resolvedMousePoint(
            kind: kind,
            normalizedPoint: normalizedPoint,
            lastLeftPoint: lastEnqueuedLeftMousePoint,
            lastRightPoint: lastEnqueuedRightMousePoint
        ) else {
            return
        }
        let relativeDelta: CGPoint
        if kind.isCoalescibleMotion {
            let previousPoint: CGPoint?
            switch kind {
            case .leftMouseDragged:
                previousPoint = lastEnqueuedLeftMousePoint
            case .rightMouseDragged:
                previousPoint = lastEnqueuedRightMousePoint
            default:
                previousPoint = nil
            }
            relativeDelta = Self.resolvedMouseDelta(
                reportedDelta: CGPoint(x: event.deltaX, y: event.deltaY),
                previousPoint: previousPoint,
                currentPoint: point,
                in: bounds,
                sourceFrameSize: remoteFrameView.framePixelSize
            ) ?? .zero
        } else {
            relativeDelta = .zero
        }
        guard inputPump.enqueue(ApplicationSurfaceInputEvent(
            kind: kind,
            frameSequence: remoteFrameView.presentedFrameSequence ?? 0,
            x: point.x,
            y: point.y,
            modifiers: UInt64(event.modifierFlags.rawValue),
            clickCount: event.clickCount,
            deltaX: relativeDelta.x,
            deltaY: relativeDelta.y
        )) == .accepted else {
            handleInputQueueFull()
            return
        }
        switch kind {
        case .leftMouseDown, .leftMouseDragged:
            lastEnqueuedLeftMousePoint = point
        case .leftMouseUp:
            lastEnqueuedLeftMousePoint = nil
        case .rightMouseDown, .rightMouseDragged:
            lastEnqueuedRightMousePoint = point
        case .rightMouseUp:
            lastEnqueuedRightMousePoint = nil
        default:
            break
        }
    }

    @discardableResult
    private func enqueueKey(_ event: NSEvent, keyDown: Bool) -> Bool {
        guard canForwardInput else { return false }
        guard inputPump.enqueue(ApplicationSurfaceInputEvent(
            kind: .key,
            keyCode: event.keyCode,
            keyDown: keyDown,
            modifiers: UInt64(event.modifierFlags.rawValue)
        )) == .accepted else {
            handleInputQueueFull()
            return false
        }
        return true
    }

    private func enqueueBalancedKeyPress(
        keyCode: UInt16,
        modifiers: UInt64
    ) -> ApplicationSurfaceInputEnqueueResult {
        inputPump.enqueue([
            ApplicationSurfaceInputEvent(
                kind: .key,
                keyCode: keyCode,
                keyDown: true,
                modifiers: modifiers
            ),
            ApplicationSurfaceInputEvent(
                kind: .key,
                keyCode: keyCode,
                keyDown: false,
                modifiers: modifiers
            ),
        ])
    }

    private func normalizedPoint(for event: NSEvent) -> CGPoint? {
        guard canForwardInput else { return nil }
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

    private var shouldCaptureNow: Bool {
        captureActivity.ownsSession
    }

    private var captureActivity: ApplicationCaptureActivity {
        ApplicationCaptureActivity(
            paneWantsCapture: captureDesired,
            hostAttached: hostWindowAttached,
            hostVisible: hostWindowVisible
        )
    }

    private var canForwardInput: Bool {
        Self.inputIsReady(
            hasInputOwnership: hasInputOwnership,
            activity: captureActivity,
            hasSession: session != nil,
            hasLease: lease != nil,
            attachmentAcknowledged: attachmentAcknowledged,
            firstFramePresented: firstFramePresented,
            isReleasingInput: inputReleaseTask != nil,
            isStopping: stopTask != nil
        )
    }

    static func inputIsReady(
        hasInputOwnership: Bool,
        activity: ApplicationCaptureActivity,
        hasSession: Bool,
        hasLease: Bool,
        attachmentAcknowledged: Bool,
        firstFramePresented: Bool,
        isReleasingInput: Bool,
        isStopping: Bool
    ) -> Bool {
        hasInputOwnership
            && activity.acceptsInput
            && hasSession
            && hasLease
            && attachmentAcknowledged
            && firstFramePresented
            && !isReleasingInput
            && !isStopping
    }

    private func reconcileCaptureActivity() {
        let shouldCaptureNow = shouldCaptureNow
        remoteFrameView.setActive(shouldCaptureNow && session != nil)
        if shouldCaptureNow {
            startCapture()
        } else {
            suspendCapture(reportState: captureDesired || session != nil)
        }
    }

    @discardableResult
    private func beginInputRelease(
        session: ApplicationSurfaceSessionDescriptor?,
        lease: ApplicationSurfaceRuntimeLease?
    ) -> Task<Void, Never> {
        pendingScrollX = 0
        pendingScrollY = 0
        pressedModifierKeyCodes.removeAll()
        currentModifierKeyCodes.removeAll()
        lastEnqueuedLeftMousePoint = nil
        lastEnqueuedRightMousePoint = nil
        if let inputReleaseTask {
            return inputReleaseTask
        }

        inputPump.discardPending()
        let generation = UUID()
        inputReleaseGeneration = generation
        let runtime = runtime
        let inputPump = inputPump
        let task = Task { @MainActor [weak self] in
            let released = await inputPump.releasePossibleInputsAfterDraining(
                maximumAttemptCount: Self.maximumInputReleaseAttemptCount
            ) { events in
                guard let session, let lease else { return false }
                do {
                    try await runtime.sendApplicationSurfaceEvents(
                        lease: lease,
                        sessionID: session.sessionID,
                        events: events
                    )
                    return true
                } catch {
                    return false
                }
            }
            guard
                let self,
                self.inputReleaseGeneration == generation
            else {
                return
            }
            if !released, session != nil, lease != nil {
                cmuxDebugLog(
                    "applicationSurface.input.releaseFailed"
                        + " window=\(self.sourceWindowID)"
                )
                self.handleRuntimeFailure(
                    .failed,
                    failureDetail: Self.genericCaptureFailureDetail
                )
            }
            self.inputReleaseTask = nil
            self.refreshPhysicalModifierKeysAndSynchronizeIfFocused()
            if self.shouldCaptureNow {
                self.startCapture()
            }
        }
        inputReleaseTask = task
        return task
    }

    private func beginLivenessWatchdog(generation: UUID) {
        stopLivenessWatchdog()
        guard hostWindowVisible else { return }
        livenessState = ApplicationCaptureLivenessState(
            startedAt: ProcessInfo.processInfo.systemUptime
        )
        let clock = ContinuousClock()
        livenessTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(
                    for: .seconds(Self.firstFrameTimeout)
                )
            } catch {
                return
            }
            guard
                let self,
                self.captureGeneration == generation,
                self.shouldCaptureNow,
                self.hostWindowVisible,
                self.session != nil,
                let failure = self.livenessState?.failure(
                    at: ProcessInfo.processInfo.systemUptime,
                    firstFrameTimeout: Self.firstFrameTimeout
                )
            else {
                return
            }
            cmuxDebugLog(
                "applicationSurface.frames.failed"
                    + " window=\(self.sourceWindowID)"
                    + " reason=\(String(describing: failure))"
            )
            self.handleRuntimeFailure(
                .failed,
                failureDetail: Self.genericCaptureFailureDetail
            )
        }
    }

    private func beginRuntimeFailureObservation(
        lease: ApplicationSurfaceRuntimeLease,
        session: ApplicationSurfaceSessionDescriptor,
        generation: UUID
    ) {
        runtimeFailureTask?.cancel()
        let failures = runtime.applicationSurfaceFailureEvents(
            lease: lease,
            sessionID: session.sessionID
        )
        runtimeFailureTask = Task { @MainActor [weak self] in
            for await failure in failures {
                guard
                    let self,
                    !Task.isCancelled,
                    self.captureGeneration == generation,
                    self.session?.sessionID == session.sessionID
                else {
                    return
                }
                switch failure {
                case .permissionRequired:
                    self.handleRuntimeFailure(
                        .permissionRequired,
                        failureDetail: failure.localizedDescription
                    )
                case .windowUnavailable:
                    self.handleRuntimeFailure(
                        .windowUnavailable,
                        failureDetail: failure.localizedDescription
                    )
                case .helperUnavailable, .resourceLimit, .invalidResponse:
                    self.handleRuntimeFailure(
                        .failed,
                        failureDetail: failure.localizedDescription
                    )
                case .pointOutsideContent, .captureUnavailable:
                    continue
                }
                return
            }
        }
    }

    private func stopLivenessWatchdog() {
        livenessTask?.cancel()
        livenessTask = nil
        livenessState = nil
    }

    private func recordPresentedFrame() {
        guard shouldCaptureNow, session != nil else { return }
        livenessState?.recordFrame(at: ProcessInfo.processInfo.systemUptime)
        stopLivenessWatchdog()
    }

    private func publishCaptureReadinessIfReady() {
        guard
            attachmentAcknowledged,
            firstFramePresented,
            !captureReadinessPublished
        else {
            return
        }
        captureReadinessPublished = true
        onStateChanged(.streaming, nil)
        refreshPhysicalModifierKeysAndSynchronizeIfFocused()
    }

    @objc private func hostWindowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        releaseForwardedInputs()
    }

    @objc private func hostWindowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        refreshPhysicalModifierKeysAndSynchronizeIfFocused()
    }

    private func handleRuntimeFailure(
        _ state: ApplicationCaptureState,
        failureDetail: String?
    ) {
        guard captureDesired else { return }
        if state == .windowUnavailable {
            targetUnavailable = true
        }
        onStateChanged(state, failureDetail)
        stopCapture()
    }

    private func handleInputQueueFull() {
        cmuxDebugLog(
            "applicationSurface.input.queueFull"
                + " window=\(sourceWindowID)"
        )
        handleRuntimeFailure(
            .failed,
            failureDetail: Self.genericCaptureFailureDetail
        )
    }

    private static var genericCaptureFailureDetail: String {
        String(
            localized: "panel.application.captureFailed.detail",
            defaultValue: "cmux could not capture this window. Try again or choose another window."
        )
    }

    static func localizedTransportFailureDetail(
        _ failure: CmuxRemoteFrameTransportFailure
    ) -> String {
        switch failure {
        case .invalidTransport, .producerFailed:
            genericCaptureFailureDetail
        }
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

    static func modifierKeyIsDown(
        keyCode: UInt16,
        modifierFlagsRawValue: UInt
    ) -> Bool? {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
        switch Int(keyCode) {
        case kVK_CapsLock:
            return flags.contains(.capsLock)
        case kVK_Shift:
            return flags.contains(.shift)
                && modifierFlagsRawValue
                    & UInt(NX_DEVICELSHIFTKEYMASK) != 0
        case kVK_RightShift:
            return flags.contains(.shift)
                && modifierFlagsRawValue
                    & UInt(NX_DEVICERSHIFTKEYMASK) != 0
        case kVK_Control:
            return flags.contains(.control)
                && modifierFlagsRawValue
                    & UInt(NX_DEVICELCTLKEYMASK) != 0
        case kVK_RightControl:
            return flags.contains(.control)
                && modifierFlagsRawValue
                    & UInt(NX_DEVICERCTLKEYMASK) != 0
        case kVK_Option:
            return flags.contains(.option)
                && modifierFlagsRawValue
                    & UInt(NX_DEVICELALTKEYMASK) != 0
        case kVK_RightOption:
            return flags.contains(.option)
                && modifierFlagsRawValue
                    & UInt(NX_DEVICERALTKEYMASK) != 0
        case kVK_Command:
            return flags.contains(.command)
                && modifierFlagsRawValue
                    & UInt(NX_DEVICELCMDKEYMASK) != 0
        case kVK_RightCommand:
            return flags.contains(.command)
                && modifierFlagsRawValue
                    & UInt(NX_DEVICERCMDKEYMASK) != 0
        case kVK_Function:
            return flags.contains(.function)
        default:
            return nil
        }
    }

    private static func modifierKeyCodes(
        modifierFlagsRawValue: UInt
    ) -> Set<UInt16> {
        let keyCodes = [
            kVK_Command, kVK_RightCommand,
            kVK_Shift, kVK_RightShift,
            kVK_Option, kVK_RightOption,
            kVK_Control, kVK_RightControl,
            kVK_CapsLock, kVK_Function,
        ]
        return Set(keyCodes.compactMap { keyCode in
            modifierKeyIsDown(
                keyCode: UInt16(keyCode),
                modifierFlagsRawValue: modifierFlagsRawValue
            ) == true ? UInt16(keyCode) : nil
        })
    }

    static func resolvedMousePoint(
        kind: ApplicationSurfaceInputEventKind,
        normalizedPoint: CGPoint?,
        lastLeftPoint: CGPoint?,
        lastRightPoint: CGPoint?
    ) -> CGPoint? {
        if let normalizedPoint {
            return normalizedPoint
        }
        switch kind {
        case .leftMouseDragged, .leftMouseUp:
            return lastLeftPoint
        case .rightMouseDragged, .rightMouseUp:
            return lastRightPoint
        default:
            return nil
        }
    }

    private func synchronizeForwardedModifierKeys() {
        guard canForwardInput else { return }
        let releases = pressedModifierKeyCodes
            .subtracting(currentModifierKeyCodes)
            .sorted()
            .map {
                ApplicationSurfaceInputEvent(
                    kind: .key,
                    keyCode: $0,
                    keyDown: false
                )
            }
        let presses = currentModifierKeyCodes
            .subtracting(pressedModifierKeyCodes)
            .sorted()
            .map {
                ApplicationSurfaceInputEvent(
                    kind: .key,
                    keyCode: $0,
                    keyDown: true
                )
            }
        let transitions = releases + presses
        guard !transitions.isEmpty else { return }
        guard inputPump.enqueue(transitions) == .accepted else {
            handleInputQueueFull()
            return
        }
        pressedModifierKeyCodes = currentModifierKeyCodes
    }

    private func refreshPhysicalModifierKeys() {
        currentModifierKeyCodes = Self.modifierKeyCodes(
            modifierFlagsRawValue: modifierFlagsRawValueProvider()
        )
    }

    private func refreshPhysicalModifierKeysAndSynchronizeIfFocused() {
        guard
            window?.firstResponder === self,
            window?.isKeyWindow == true
        else {
            return
        }
        refreshPhysicalModifierKeys()
        synchronizeForwardedModifierKeys()
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

    static func resolvedMouseDelta(
        reportedDelta: CGPoint,
        previousPoint: CGPoint?,
        currentPoint: CGPoint,
        in bounds: CGRect,
        sourceFrameSize: CGSize
    ) -> CGPoint? {
        guard reportedDelta.x.isFinite, reportedDelta.y.isFinite else {
            return nil
        }
        guard let previousPoint else { return reportedDelta }
        let scale = min(
            bounds.width / sourceFrameSize.width,
            bounds.height / sourceFrameSize.height
        )
        let fallback: CGPoint
        if
            bounds.width > 0,
            bounds.height > 0,
            sourceFrameSize.width > 0,
            sourceFrameSize.height > 0,
            scale.isFinite,
            scale > 0
        {
            fallback = CGPoint(
                x: (currentPoint.x - previousPoint.x) * sourceFrameSize.width * scale,
                y: (currentPoint.y - previousPoint.y) * sourceFrameSize.height * scale
            )
        } else {
            fallback = .zero
        }
        return CGPoint(
            x: reportedDelta.x == 0 ? fallback.x : reportedDelta.x,
            y: reportedDelta.y == 0 ? fallback.y : reportedDelta.y
        )
    }

}
