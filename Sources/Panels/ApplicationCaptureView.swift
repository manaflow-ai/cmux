import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import os
import ScreenCaptureKit

@MainActor
final class ApplicationCaptureView: NSView {
    private static let targetValidationInterval: TimeInterval = 0.25
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cmux",
        category: "ApplicationCapture"
    )
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

    private let sourceWindowID: CGWindowID
    private let processID: pid_t
    private let targetFrameRate: Int
    private let onStateChanged: (ApplicationPanel.CaptureState) -> Void
    private let onMovedToWindow: (ApplicationCaptureView) -> Void
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let streamOutput: ApplicationCaptureStreamOutput
    private let streamDelegate: ApplicationCaptureStreamDelegate
    private var captureTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var startupToken: UUID?
    private var stream: SCStream?
    private var sourceFrame: CGRect = .zero
    private var lastTargetValidationAt: TimeInterval = 0
    private var captureDesired = false
    private var targetUnavailable = false
    private var pendingScrollX = 0.0
    private var pendingScrollY = 0.0
    private var mouseTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(
        windowID: CGWindowID,
        processID: pid_t,
        targetFrameRate: Int,
        onStateChanged: @escaping (ApplicationPanel.CaptureState) -> Void,
        onMovedToWindow: @escaping (ApplicationCaptureView) -> Void
    ) {
        self.sourceWindowID = windowID
        self.processID = processID
        self.targetFrameRate = targetFrameRate
        self.onStateChanged = onStateChanged
        self.onMovedToWindow = onMovedToWindow
        self.streamOutput = ApplicationCaptureStreamOutput(displayLayer: displayLayer)
        self.streamDelegate = ApplicationCaptureStreamDelegate {
            Task { @MainActor in
                onStateChanged(.failed)
            }
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func setCaptureActive(_ active: Bool) {
        if active {
            captureDesired = true
            startCapture()
        } else {
            stopCapture()
        }
    }

    func startCapture() {
        guard captureDesired, !targetUnavailable, captureTask == nil, stream == nil else { return }
        let token = UUID()
        startupToken = token
        let previousTeardown = teardownTask
        captureTask = Task { [weak self] in
            await previousTeardown?.value
            guard let self,
                  self.captureDesired,
                  self.startupToken == token,
                  !Task.isCancelled else { return }
            await self.beginCapture(token: token)
            if self.startupToken == token {
                self.captureTask = nil
            }
        }
    }

    func stopCapture() {
        captureDesired = false
        startupToken = nil
        captureTask?.cancel()
        captureTask = nil
        sourceFrame = .zero
        lastTargetValidationAt = 0
        pendingScrollX = 0
        pendingScrollY = 0

        let activeStream = stream
        stream = nil
        displayLayer.flushAndRemoveImage()
        guard let activeStream else { return }

        streamDelegate.expectStop(activeStream)
        let previousTeardown = teardownTask
        teardownTask = Task {
            await previousTeardown?.value
            do {
                try await activeStream.stopCapture()
            } catch {
                Self.logger.error("ScreenCaptureKit stopCapture failed")
            }
        }
    }

    private func beginCapture(token: UUID) async {
        onStateChanged(.starting)
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            onStateChanged(.permissionRequired)
            return
        }
        guard captureDesired, startupToken == token, !Task.isCancelled else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard captureDesired, startupToken == token, !Task.isCancelled else { return }
            guard let sourceWindow = content.windows.first(where: {
                $0.windowID == sourceWindowID
            }),
            sourceWindow.owningApplication?.processID == processID else {
                handleWindowUnavailable()
                return
            }

            sourceFrame = sourceWindow.frame
            lastTargetValidationAt = CFAbsoluteTimeGetCurrent()
            let filter = SCContentFilter(desktopIndependentWindow: sourceWindow)
            let configuration = SCStreamConfiguration()
            let sourceSize = sourceWindow.frame.size
            let captureScale = min(
                2,
                4_096 / max(sourceSize.width, 1),
                2_304 / max(sourceSize.height, 1)
            )
            configuration.width = max(Int(sourceSize.width * captureScale), 1)
            configuration.height = max(Int(sourceSize.height * captureScale), 1)
            configuration.minimumFrameInterval = CMTime(
                value: 1,
                timescale: CMTimeScale(targetFrameRate)
            )
            configuration.queueDepth = 3
            configuration.showsCursor = true
            configuration.pixelFormat = kCVPixelFormatType_32BGRA

            let newStream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: streamDelegate
            )
            try newStream.addStreamOutput(
                streamOutput,
                type: .screen,
                sampleHandlerQueue: streamOutput.sampleQueue
            )
            stream = newStream
            try await newStream.startCapture()
            guard captureDesired, startupToken == token, !Task.isCancelled else {
                if stream === newStream {
                    stream = nil
                    streamDelegate.expectStop(newStream)
                    do {
                        try await newStream.stopCapture()
                    } catch {
                        Self.logger.error("ScreenCaptureKit cancelled-start teardown failed")
                    }
                }
                return
            }
            onStateChanged(.streaming)
        } catch {
            stream = nil
            if captureDesired, startupToken == token, !Task.isCancelled {
                onStateChanged(.failed)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        postMouse(event, type: .leftMouseDown, button: .left)
    }

    override func mouseUp(with event: NSEvent) {
        postMouse(event, type: .leftMouseUp, button: .left)
    }

    override func rightMouseDown(with event: NSEvent) {
        postMouse(event, type: .rightMouseDown, button: .right)
    }

    override func rightMouseUp(with event: NSEvent) {
        postMouse(event, type: .rightMouseUp, button: .right)
    }

    override func mouseMoved(with event: NSEvent) {
        postMouse(event, type: .mouseMoved, button: .left)
    }

    override func mouseDragged(with event: NSEvent) {
        postMouse(event, type: .leftMouseDragged, button: .left)
    }

    override func rightMouseDragged(with event: NSEvent) {
        postMouse(event, type: .rightMouseDragged, button: .right)
    }

    override func scrollWheel(with event: NSEvent) {
        guard validatedSourceFrame() != nil, AXIsProcessTrusted() else { return }
        pendingScrollX += event.scrollingDeltaX
        pendingScrollY += event.scrollingDeltaY
        let scrollX = pendingScrollX.rounded(.towardZero)
        let scrollY = pendingScrollY.rounded(.towardZero)
        pendingScrollX -= scrollX
        pendingScrollY -= scrollY
        guard scrollX != 0 || scrollY != 0 else { return }
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(scrollY),
            wheel2: Int32(scrollX),
            wheel3: 0
        ) else { return }
        cgEvent.postToPid(processID)
    }

    override func keyDown(with event: NSEvent) {
        postKey(event, keyDown: true)
    }

    override func keyUp(with event: NSEvent) {
        postKey(event, keyDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        let modifier: NSEvent.ModifierFlags
        switch Int(event.keyCode) {
        case kVK_Command, kVK_RightCommand:
            modifier = .command
        case kVK_Shift, kVK_RightShift:
            modifier = .shift
        case kVK_Option, kVK_RightOption:
            modifier = .option
        case kVK_Control, kVK_RightControl:
            modifier = .control
        case kVK_CapsLock:
            modifier = .capsLock
        case kVK_Function:
            modifier = .function
        default:
            return
        }
        postKey(event, keyDown: event.modifierFlags.contains(modifier))
    }

    func sendNamedKey(_ name: String) -> ApplicationNamedKeySendResult {
        guard let parsed = Self.parseNamedKey(name) else {
            return .unknownKey
        }
        guard validatedSourceFrame() != nil, AXIsProcessTrusted(),
              let down = CGEvent(
                keyboardEventSource: nil,
                virtualKey: parsed.keyCode,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: nil,
                virtualKey: parsed.keyCode,
                keyDown: false
              ) else {
            return .surfaceUnavailable
        }
        down.flags = parsed.flags
        up.flags = parsed.flags
        down.postToPid(processID)
        up.postToPid(processID)
        return .sent
    }

    static func parseNamedKey(_ name: String) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        let normalized = name
            .lowercased()
            .replacingOccurrences(of: "+", with: "-")
        var components = normalized.split(separator: "-").map(String.init)
        guard let keyName = components.popLast(),
              let keyCode = Self.namedKeyCodes[keyName] else {
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

    private func postMouse(_ event: NSEvent, type: CGEventType, button: CGMouseButton) {
        guard let sourceFrame = validatedSourceFrame(), AXIsProcessTrusted() else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let sourcePoint = Self.sourcePoint(
            for: point,
            in: bounds,
            sourceFrame: sourceFrame
        ) else { return }
        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: sourcePoint,
            mouseButton: button
        ) else { return }
        cgEvent.postToPid(processID)
    }

    static func sourcePoint(
        for point: CGPoint,
        in bounds: CGRect,
        sourceFrame: CGRect
    ) -> CGPoint? {
        guard bounds.width > 0,
              bounds.height > 0,
              sourceFrame.width > 0,
              sourceFrame.height > 0 else { return nil }
        let scale = min(bounds.width / sourceFrame.width, bounds.height / sourceFrame.height)
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

    private func validatedSourceFrame() -> CGRect? {
        guard captureDesired, stream != nil, sourceFrame.width > 0, sourceFrame.height > 0 else {
            return nil
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTargetValidationAt < Self.targetValidationInterval {
            return sourceFrame
        }
        lastTargetValidationAt = now

        let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            sourceWindowID
        ) as? [[String: Any]]
        guard let window = windows?.first,
              let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
              pid_t(ownerPID) == processID,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary else {
            handleWindowUnavailable()
            return nil
        }
        var frame = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(bounds, &frame),
              frame.width > 0,
              frame.height > 0 else {
            handleWindowUnavailable()
            return nil
        }
        sourceFrame = frame
        return frame
    }

    private func postKey(_ event: NSEvent, keyDown: Bool) {
        guard validatedSourceFrame() != nil, AXIsProcessTrusted() else { return }
        guard let cgEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(event.keyCode),
            keyDown: keyDown
        ) else { return }
        cgEvent.flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        cgEvent.postToPid(processID)
    }

    private func handleWindowUnavailable() {
        targetUnavailable = true
        sourceFrame = .zero
        onStateChanged(.windowUnavailable)
        stopCapture()
    }
}
