import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreMedia
import ScreenCaptureKit
import SwiftUI

struct ApplicationCaptureRepresentable: NSViewRepresentable {
    let panel: ApplicationPanel
    let windowID: CGWindowID

    func makeNSView(context: Context) -> ApplicationCaptureView {
        let captureToken = panel.beginCaptureSession()
        let view = ApplicationCaptureView(
            windowID: windowID,
            processID: panel.processID,
            targetFrameRate: panel.targetFrameRate,
            onStateChanged: { [weak panel] state in
                panel?.updateCaptureState(state, token: captureToken)
            }
        )
        panel.attach(view, token: captureToken)
        view.startCapture()
        return view
    }

    func updateNSView(_ nsView: ApplicationCaptureView, context: Context) {}

    static func dismantleNSView(_ nsView: ApplicationCaptureView, coordinator: ()) {
        nsView.stopCapture()
    }
}

final class ApplicationCaptureView: NSView {
    private let sourceWindowID: CGWindowID
    private let processID: pid_t
    private let targetFrameRate: Int
    private let onStateChanged: (ApplicationPanel.CaptureState) -> Void
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let streamOutput: ApplicationCaptureStreamOutput
    private let streamDelegate: ApplicationCaptureStreamDelegate
    private var captureTask: Task<Void, Never>?
    private var stream: SCStream?
    private var sourceFrame: CGRect = .zero
    private var pendingScrollX = 0.0
    private var pendingScrollY = 0.0

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(
        windowID: CGWindowID,
        processID: pid_t,
        targetFrameRate: Int,
        onStateChanged: @escaping (ApplicationPanel.CaptureState) -> Void
    ) {
        self.sourceWindowID = windowID
        self.processID = processID
        self.targetFrameRate = targetFrameRate
        self.onStateChanged = onStateChanged
        self.streamOutput = ApplicationCaptureStreamOutput(displayLayer: displayLayer)
        self.streamDelegate = ApplicationCaptureStreamDelegate { detail in
            Task { @MainActor in
                onStateChanged(.failed(detail))
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

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func startCapture() {
        guard captureTask == nil else { return }
        captureTask = Task { [weak self] in
            await self?.beginCapture()
        }
    }

    func stopCapture() {
        captureTask?.cancel()
        captureTask = nil
        let activeStream = stream
        stream = nil
        Task {
            try? await activeStream?.stopCapture()
        }
        displayLayer.flushAndRemoveImage()
    }

    private func beginCapture() async {
        onStateChanged(.starting)
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            onStateChanged(.permissionRequired)
            return
        }
        guard !Task.isCancelled else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard !Task.isCancelled else { return }
            guard let sourceWindow = content.windows.first(where: {
                $0.windowID == sourceWindowID
            }) else {
                onStateChanged(.windowUnavailable)
                return
            }
            sourceFrame = sourceWindow.frame
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
            guard !Task.isCancelled else {
                if stream === newStream {
                    stream = nil
                }
                try? await newStream.stopCapture()
                return
            }
            onStateChanged(.streaming)
        } catch {
            stream = nil
            if !Task.isCancelled {
                onStateChanged(.failed(error.localizedDescription))
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

    func sendNamedKey(_ name: String) -> Bool {
        let normalized = name.lowercased()
        let keys: [String: CGKeyCode] = [
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
        var components = normalized.split(separator: "-").map(String.init)
        guard let keyName = components.popLast(), let keyCode = keys[keyName] else {
            return false
        }
        var flags: CGEventFlags = []
        for modifier in components {
            switch modifier {
            case "ctrl", "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "cmd", "command", "super": flags.insert(.maskCommand)
            default: return false
            }
        }
        guard let down = CGEvent(
                keyboardEventSource: nil,
                virtualKey: keyCode,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: nil,
                virtualKey: keyCode,
                keyDown: false
              ) else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(processID)
        up.postToPid(processID)
        return true
    }

    private func postMouse(_ event: NSEvent, type: CGEventType, button: CGMouseButton) {
        if let currentFrame = currentSourceFrame() {
            sourceFrame = currentFrame
        }
        guard sourceFrame.width > 0, sourceFrame.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / sourceFrame.width, bounds.height / sourceFrame.height)
        guard scale > 0 else { return }
        let renderedSize = CGSize(
            width: sourceFrame.width * scale,
            height: sourceFrame.height * scale
        )
        let insetX = (bounds.width - renderedSize.width) / 2
        let insetY = (bounds.height - renderedSize.height) / 2
        let sourcePoint = CGPoint(
            x: sourceFrame.minX + min(max((point.x - insetX) / scale, 0), sourceFrame.width),
            y: sourceFrame.minY + min(max((point.y - insetY) / scale, 0), sourceFrame.height)
        )
        guard let cgEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: sourcePoint,
            mouseButton: button
        ) else { return }
        cgEvent.postToPid(processID)
    }

    private func currentSourceFrame() -> CGRect? {
        let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            sourceWindowID
        ) as? [[String: Any]]
        guard let bounds = windows?.first?[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        var frame = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(bounds, &frame) else {
            return nil
        }
        return frame
    }

    private func postKey(_ event: NSEvent, keyDown: Bool) {
        guard let cgEvent = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(event.keyCode),
                keyDown: keyDown
              ) else { return }
        cgEvent.flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        cgEvent.postToPid(processID)
    }
}

private final class ApplicationCaptureStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let onStopped: @Sendable (String) -> Void

    init(onStopped: @escaping @Sendable (String) -> Void) {
        self.onStopped = onStopped
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped(error.localizedDescription)
    }
}

private final class ApplicationCaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let sampleQueue = DispatchQueue(
        label: "com.cmux.application-capture.frames",
        qos: .userInteractive
    )
    private let displayLayer: AVSampleBufferDisplayLayer

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        displayLayer.enqueue(sampleBuffer)
    }
}
