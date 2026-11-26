import CoreGraphics
import Foundation

// Follow mode's focus signals (host → viewer, the `focus` data channel): where
// the person's attention is on the streamed display, for the viewer's follow
// camera (cmux-tui/crates/cmux-follow-cam). One JSON `Event` per message:
// `{"t_us":…,"kind":"pointer","x":…,"y":…}`, coordinates in the streamed
// display's pixels (its full native size, the `source` event's `w`×`h`; the
// video is that picture uniformly scaled), origin top left, `t_us` this Mac's
// monotonic clock in microseconds. Sent only to a viewer that opened `focus`.

/// The streamed display, for converting global coordinates to its pixels
/// (the conversion is cmux-rd-screen's `FocusGeometry`).
struct FocusGeometry: Equatable, Sendable {
    /// The display's frame in global display coordinates (points, origin at
    /// the main display's top left, y down: CGEvent, CGWindowList and AX).
    var display: CGRect
    /// The display's native size in pixels.
    var pixels: CGSize
}

/// The focused window: its CGWindowList number (stable while it lives) and
/// frame in global display coordinates.
struct FocusWindow: Equatable, Sendable {
    var id: UInt64
    var frame: CGRect
    /// The owning process (for the caret: that app's focused element).
    var pid: pid_t = 0
}

/// Where the focus signals come from, in global display coordinates (points,
/// top left origin). The live one reads CGEvent, CGWindowList and the
/// Accessibility API (``FocusSignalProducer/systemProbe()``); tests inject one.
protocol FocusProbe: Sendable {
    /// The mouse pointer.
    func pointer() -> CGPoint?
    /// The frontmost app's frontmost window (no Accessibility grant needed).
    func focusedWindow() -> FocusWindow?
    /// The text caret of the focused element; nil without the Accessibility
    /// grant or when the focused element has none.
    func caret() -> CGRect?
}

/// Samples the probe about 30 times a second and sends what changed, each
/// signal at its own rate: the pointer every tick (~30/s), the caret every
/// 2nd (~15/s), the window every 6th (~5/s), damage every 3rd (at most 3
/// regions: ≤ 30 messages/s). Once a second (and after a send failed, when
/// the channel opens) the source size, pointer, window and caret go again,
/// so a late or reconnected follower starts complete. The rules (rates,
/// geometry, damage regions, the messages) are cmux-rd-screen's
/// `FocusProducer` (ops `screen_focus_tick`, `screen_focus_damage`); this
/// reads the probe and keeps the producer's state.
// crash-allow: state is read and written only under `lock`; ticks run one at a time on `queue`.
final class FocusSignalProducer: @unchecked Sendable {
    static let ticksPerSecond = 30
    static let caretEvery = 2
    static let windowEvery = 6

    private let rules: ScreenRules
    private let probe: any FocusProbe
    private let geometry: @Sendable () -> FocusGeometry?
    private let send: @Sendable (String) -> Bool
    private let queue = DispatchQueue(label: "cmux.screen.focus", qos: .userInitiated)
    private let lock = NSLock()
    private var state: ScreenJSON?

    init(rules: ScreenRules = ScreenRules(), probe: any FocusProbe, geometry: @escaping @Sendable () -> FocusGeometry?,
         send: @escaping @Sendable (String) -> Bool) {
        self.rules = rules
        self.probe = probe
        self.geometry = geometry
        self.send = send
    }

    private struct Geometry: Encodable {
        var display: ScreenRect, pixels: ScreenSize
        init(_ geometry: FocusGeometry) {
            display = ScreenRect(geometry.display)
            pixels = ScreenSize(geometry.pixels)
        }
    }

    private struct Window: Encodable {
        var id: UInt64, frame: ScreenRect, pid: Int32
    }

    /// One captured picture's changed rects, in that picture's pixels
    /// (`captured` its size). Any thread.
    func damage(_ rects: [CGRect], captured: CGSize) {
        struct Request: Encodable { var producer: ScreenJSON?, geometry: Geometry?, rects: [ScreenRect], captured: ScreenSize }
        struct Answer: Decodable { var producer: ScreenJSON }
        guard let geometry = geometry(), !rects.isEmpty else { return }
        lock.withLock {
            let request = Request(producer: state, geometry: Geometry(geometry), rects: rects.map(ScreenRect.init), captured: ScreenSize(captured))
            if let answer = rules.ask("screen_focus_damage", request, as: Answer.self) { state = answer.producer }
        }
    }

    /// This Mac's monotonic clock, in microseconds (every event's `t_us`).
    static func nowMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1000
    }

    /// One sample and send. Called one at a time (``run(channelOpen:)``, tests).
    func tick(now: UInt64) {
        struct Sample: Encodable { var geometry: Geometry?, pointer: ScreenPoint?, window: Window?, caret: ScreenRect? }
        struct Request: Encodable { var producer: ScreenJSON?, sample: Sample, nowUs: UInt64 }
        struct Answer: Decodable { var messages: [String], sent: ScreenJSON, failed: ScreenJSON }
        // The probe is IPC (AX, the window list): read each signal only on the ticks the producer uses it.
        let (tick, resync) = lock.withLock { (state?["ticks"]?.int ?? 0, state?["resync"]?.bool ?? true) }
        let full = resync || tick % Self.ticksPerSecond == 0
        let geometry = geometry()
        var sample = Sample(geometry: geometry.map(Geometry.init))
        if geometry != nil {
            sample.pointer = probe.pointer().map(ScreenPoint.init)
            if full || tick % Self.windowEvery == 0, let window = probe.focusedWindow() {
                sample.window = Window(id: window.id, frame: ScreenRect(window.frame), pid: window.pid)
            }
            if full || tick % Self.caretEvery == 0 { sample.caret = probe.caret().map(ScreenRect.init) }
        }
        lock.withLock {
            guard let answer = rules.ask("screen_focus_tick", Request(producer: state, sample: sample, nowUs: now), as: Answer.self)
            else { return }
            // A refused send (the channel is not open yet): everything goes again once it is.
            state = answer.messages.allSatisfy(send) ? answer.sent : answer.failed
        }
    }

    /// Samples until cancelled, off the caller's thread (AX and the window
    /// list are IPC). Stops early when the viewer never opens `focus` (an
    /// older viewer) within 10 s.
    func run(channelOpen: @escaping @Sendable () -> Bool) async {
        var waited = 0
        var opened = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1000 / Self.ticksPerSecond)) // focus sampling period
            guard channelOpen() else {
                waited += 1
                if !opened, waited > 10 * Self.ticksPerSecond { return }
                continue
            }
            opened = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    self.tick(now: Self.nowMicroseconds())
                    continuation.resume()
                }
            }
        }
    }
}

/// A screen source that reports which parts of each captured picture
/// changed: rects in that picture's pixels (top left origin) and its size.
/// The one damage feed (ScreenCaptureKit's `dirtyRects`); any thread.
protocol ScreenDamageSource: AnyObject {
    var onDamage: (@Sendable ([CGRect], CGSize) -> Void)? { get set }
}
