import CmuxNextCompat
import Darwin

/// The main-thread steps of Chromium's start, counted as
/// `MainThreadEngineStart` time so control deadlines skip them:
/// `CefInitialize`, and Chromium's work from the first `create_window` until
/// that window exists (or its creation fails). Chromium builds its first
/// browser window in that work: in a macOS 26 VM the window alone held the
/// main thread for about 0.8 s, after a CefInitialize of about 0.8 s, and an
/// `action.run` that opened the first Chromium tab missed its 2 s deadline
/// although nothing it waited for was slow (os-smoke, 2026-10-18).
final class CEFStartSteps {
    static let shared = CEFStartSteps()

    /// True from the first `create_window` until that window exists or
    /// fails; false again after.
    private(set) var firstWindowPending = false
    private var firstWindowRequested = false

    /// When each step of Chromium's start ran in this process and for how
    /// long (`debug.cef` `start_steps`): `initialize`, `make_tab` (the first
    /// tab's host and page objects), `create_window`, every pump run of 10 ms
    /// or more until the first window exists (`pump`), `first_window`
    /// (OnAfterCreated). At most 64.
    private(set) var marks: [CEFStartMark] = []
    private var madeFirstTab = false

    private func mark<T, E: Error>(_ name: String, _ body: () throws(E) -> T, keepUnder: Double = 0) throws(E) -> T {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer {
            let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1_000_000
            // Pump runs keep 8 slots free for the steps after them (first_window).
            if ms >= keepUnder, marks.count < (keepUnder > 0 ? 56 : 64) {
                marks.append(CEFStartMark(name: name, startUptimeNanos: start, milliseconds: ms))
            }
        }
        return try body()
    }

    /// A point in the first Chromium page's creation (`page_task`,
    /// `configured`, `history`): recorded once per name, with no duration.
    func point(_ name: String) {
        guard marks.count < 64, !marks.contains(where: { $0.name == name }) else { return }
        marks.append(CEFStartMark(name: name, startUptimeNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), milliseconds: 0))
    }

    /// A sub-step of the start (`cef_initialize`, `ready_hooks`): timed only.
    func timed<T>(_ name: String, _ body: () -> T) -> T { mark(name, body) }

    /// `CefInitialize` (main thread).
    func initialize<E: Error>(_ body: () throws(E) -> Void) throws(E) {
        try mark("initialize") { () throws(E) in try MainThreadEngineStart.shared.run(body) }
    }

    /// The first Chromium tab's page objects (`CEFEngine.makeReadyTab`).
    func makeTab<T>(_ body: () -> T) -> T {
        guard !madeFirstTab else { return body() }
        madeFirstTab = true
        return mark("make_tab", body)
    }

    /// The first browser window's `create_window` call.
    func createWindow(_ body: () -> Int32) -> Int32 {
        guard !firstWindowRequested else { return body() }
        let started = mark("create_window") { MainThreadEngineStart.shared.run(body) }
        firstWindowRequested = started == 1
        firstWindowPending = started == 1
        return started
    }

    /// A window exists (OnAfterCreated for a create_window request, also one
    /// whose tab closed meanwhile).
    func firstWindowEnded() {
        if firstWindowPending, marks.count < 64 {
            marks.append(CEFStartMark(name: "first_window", startUptimeNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), milliseconds: 0))
        }
        firstWindowPending = false
    }

    /// One run of the external message pump. `windowPending`: a
    /// create_window request still waits for its window; when none does
    /// (its creation ended without OnAfterCreated: a crash, shutdown) the
    /// first window's step ends too.
    func pump(windowPending: Bool, _ work: () -> Void) {
        if !windowPending { firstWindowPending = false }
        if firstWindowPending { mark("pump", { MainThreadEngineStart.shared.run(work) }, keepUnder: 10) } else { work() }
    }
}

/// One timed step of Chromium's start (`CEFStartSteps.marks`).
public struct CEFStartMark: Sendable {
    public var name: String
    /// `CLOCK_UPTIME_RAW` nanoseconds, the clock of `debug.hangs`.
    public var startUptimeNanos: UInt64
    public var milliseconds: Double
}
