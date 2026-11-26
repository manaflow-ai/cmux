import CmuxNextRemoteView
import CmuxNextCompat
import CoreGraphics
import Foundation

/// The pane's input events, sent as they are on the session's cmux.rd/1
/// transport: physical keys by HID usage (the host maps them to its own
/// layout), pointer in stream pixels, buttons, scroll in hundredths, text.
@MainActor
final class MacScreenInputSink: RemoteViewInputSink {
    weak var session: MacScreenSession?

    init(session: MacScreenSession) {
        self.session = session
    }

    func send(_ event: RemoteInputEvent) {
        session?.send(event)
    }
}

/// Counts presented frames off the main actor; every 15th frame (and the
/// first) tells the pane, which updates the stats and the picture state.
/// It also keeps the stream's frame timings (`mac_screen.state`), bounded.
nonisolated final class MacScreenFrameCounter: Sendable {
    // carve-out: counted from the decode/present callbacks, off any actor, once per frame.
    private let state = Mutex((pending: 0, timings: MacScreenFrameTimings()))
    /// The newest decoded picture, for `cmux rd screenshot` (`mac_screen.frame`). A still screen
    /// sends no new frames, so the last one is kept rather than waiting for the next.
    private let newest = Mutex<RemoteDecodedFrame?>(nil)

    /// Keeps `frame` as the newest picture (one retain; the previous one is released).
    func keep(_ frame: RemoteDecodedFrame) {
        newest.withLock { $0 = frame }
    }

    /// The newest picture this transport decoded; nil before the first.
    var latest: RemoteDecodedFrame? { newest.withLock { $0 } }

    /// Counts one frame (the host's `frame` number, released at `releasedAtNanos` and decoded at
    /// `decodedAtNanos`, `DispatchTime` uptime) as it reaches the presenter; true when the pane
    /// should hear now.
    func tick(frame: UInt32 = 0, releasedAtNanos: UInt64 = 0, decodedAtNanos: UInt64 = 0) -> Bool {
        let nowNanos = DispatchTime.now().uptimeNanoseconds, now = ContinuousClock.now
        return state.withLock { state in
            state.timings.presented(frame: frame, releasedAtNanos: releasedAtNanos, decodedAtNanos: decodedAtNanos,
                                    nowNanos: nowNanos, now: now)
            state.pending += 1
            return state.timings.total == 1 || state.pending >= 15
        }
    }

    /// A frame reached the glass (the presenter's presented handler, any thread).
    func shown(_ times: RemoteViewerFrameTimes) {
        state.withLock { $0.timings.shown(times) }
    }

    /// The stream's timings so far (a copy of a few kilobytes at most).
    var timings: MacScreenFrameTimings { state.withLock { $0.timings } }

    /// The frames counted since the last call.
    func take() -> Int {
        state.withLock { state in
            defer { state.pending = 0 }
            return state.pending
        }
    }
}

/// Scroll deltas (hundredths of a line, or of a point when precise) as the
/// whole lines the host posts, keeping the remainder.
nonisolated struct MacScreenScroll: Equatable {
    /// Hundredths per line: one wheel line, or about eight points of a trackpad swipe.
    static let hundredthsPerLine = 100.0
    static let hundredthsPerPreciseLine = 800.0
    private var remainder = (x: 0.0, y: 0.0)

    static func == (lhs: MacScreenScroll, rhs: MacScreenScroll) -> Bool { lhs.remainder == rhs.remainder }

    mutating func add(dx: Int32, dy: Int32, precise: Bool) -> (dx: Int, dy: Int) {
        let unit = precise ? Self.hundredthsPerPreciseLine : Self.hundredthsPerLine
        let x = remainder.x + Double(dx), y = remainder.y + Double(dy)
        let linesX = (x / unit).rounded(.towardZero), linesY = (y / unit).rounded(.towardZero)
        remainder = (x - linesX * unit, y - linesY * unit)
        return (Int(linesX), Int(linesY))
    }
}
