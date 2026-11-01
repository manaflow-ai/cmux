import AppKit
import QuartzCore

/// Drags a divider handle one pointer move per display refresh of the window's screen, as a
/// person's trackpad does at 120 Hz: press, then at each refresh the next offset of `path`
/// (points along the axis, positive right or down), then a still hold, then release. Each move
/// is recorded with the refresh it was sent in, so the oracle knows where the pointer was.
///
/// The events go to the handle's own mouse methods (the path a person's events take from
/// `NSWindow.sendEvent` on); a real HID pointer is not needed for the layout's drag path.
@MainActor
final class PointerDriver: NSObject {
    /// Each move: the refresh's display-link time and the pointer's offset from the press (points).
    private(set) var moves: [(time: Double, offset: Double)] = []
    /// When the release was sent (CACurrentMediaTime's clock).
    private(set) var releaseTime: Double?
    private let handle: NSView
    private let window: NSWindow
    private let start: CGPoint
    private let vertical: Bool
    private var path: [Double]
    private var holdTicks: Int
    private var link: CADisplayLink?

    /// `vertical`: the offsets move the pointer down (a row edge), else right.
    init(handle: NSView, window: NSWindow, vertical: Bool, path: [Double], holdTicks: Int = 12) {
        self.handle = handle
        self.window = window
        self.vertical = vertical
        self.path = path
        self.holdTicks = holdTicks
        start = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        super.init()
    }

    /// Presses the handle (the drag's look, its lit band, starts now).
    func press() {
        handle.mouseDown(with: event(.leftMouseDown, offset: 0))
    }

    /// Sends the moves, one per refresh, then holds still and releases; returns after the release.
    func drag() async throws {
        // concurrency-allow: a test's own display link, invalidated when the path ends
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        while releaseTime == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @objc private func tick(_ link: CADisplayLink) {
        if !path.isEmpty {
            let offset = path.removeFirst()
            moves.append((link.timestamp, offset))
            handle.mouseDragged(with: event(.leftMouseDragged, offset: offset))
        } else if holdTicks > 0 {
            holdTicks -= 1
        } else {
            handle.mouseUp(with: event(.leftMouseUp, offset: moves.last?.offset ?? 0))
            releaseTime = CACurrentMediaTime()
            link.invalidate()
            self.link = nil
        }
    }

    private func event(_ type: NSEvent.EventType, offset: Double) -> NSEvent {
        // Window points have a bottom-left origin: down in the layout is down the window's y.
        let point = vertical ? CGPoint(x: start.x, y: start.y - offset) : CGPoint(x: start.x + offset, y: start.y)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                  pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Out by `distance` points at `step` points a refresh, then back to the press point.
    static func outAndBack(distance: Double, step: Double) -> [Double] {
        let count = Int((abs(distance) / step).rounded(.up))
        let out = (1...count).map { min(Double($0) * step, abs(distance)) * (distance < 0 ? -1 : 1) }
        return out + out.reversed().dropFirst() + [0]
    }
}
