import CmuxNextRemoteView
import CmuxNextCompat
import CoreGraphics

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
nonisolated final class MacScreenFrameCounter: Sendable {
    private let state = Mutex((total: 0, pending: 0))

    /// Counts one frame; true when the pane should hear now.
    func tick() -> Bool {
        state.withLock { state in
            state.total += 1
            state.pending += 1
            return state.total == 1 || state.pending >= 15
        }
    }

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
