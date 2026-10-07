import AppKit
import CmuxBrowserStream
import CmuxMobileHost
import CoreGraphics

/// One phone on one Simulator window (see `SimulatorAppCaptureHost`).
actor SimulatorAppAttachment: SimulatorAttachment {
    nonisolated let video: any BrowserVideoSource
    private let udid: String
    private let pid: pid_t
    private let geometry: SimulatorWindowGeometry
    private let scale: Double
    private let simctl: SimctlRunner
    private let capture: ScreenCaptureFrameCapture
    private var endSinks: [AsyncStream<String>.Continuation] = []

    init(udid: String, windowID: CGWindowID, pid: pid_t, geometry: SimulatorWindowGeometry, scale: Double, simctl: SimctlRunner) {
        self.udid = udid
        self.pid = pid
        self.geometry = geometry
        self.scale = scale
        self.simctl = simctl
        let capture = ScreenCaptureFrameCapture(windowID: windowID, contentRect: geometry.contentRect)
        self.capture = capture
        video = CapturedVideoSource(capture: capture, encoder: VideoToolboxH264Encoder())
    }

    var screen: SimulatorScreen {
        let content = geometry.contentRect
        return SimulatorScreen(pointWidth: Double(content.width), pointHeight: Double(content.height), scale: scale)
    }

    func touch(_ touch: SimulatorTouch) {
        let point = geometry.globalPoint(x: touch.x, y: touch.y)
        let type: CGEventType = switch touch.phase {
        case .began: .leftMouseDown
        case .moved: .leftMouseDragged
        case .ended: .leftMouseUp
        }
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.postToPid(pid)
    }

    func text(_ text: String) {
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.postToPid(pid)
            }
        }
    }

    func key(_ event: RbKeyEvent) {
        guard let code = Self.macKeyCode(event.code) else {
            if event.down, !event.text.isEmpty { text(event.text) }
            return
        }
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: event.down)?.postToPid(pid)
    }

    func pasteboard(_ text: String) async {
        _ = try? await simctl.run(["pbcopy", udid], input: Data(text.utf8))
    }

    /// Finishes on detach; a device shutdown shows as frames stopping.
    func ended() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        endSinks.append(continuation)
        return stream
    }

    func detach() async {
        await capture.stop()
        for sink in endSinks { sink.finish() }
        endSinks = []
    }

    /// Mac virtual key codes for the keys a phone keyboard sends without text.
    static func macKeyCode(_ code: String) -> CGKeyCode? {
        switch code {
        case "Enter", "NumpadEnter": 36
        case "Tab": 48
        case "Space": 49
        case "Backspace": 51
        case "Escape": 53
        case "Delete": 117
        case "ArrowLeft": 123
        case "ArrowRight": 124
        case "ArrowDown": 125
        case "ArrowUp": 126
        case "Home": 115
        case "End": 119
        case "PageUp": 116
        case "PageDown": 121
        default: nil
        }
    }
}
