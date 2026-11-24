import CCmuxPanePicturesFFI

/// When one watched tab's hover card picture is taken again: the Rust rules of `cmux-pane-pictures` (its C ABI,
/// `include/cmux_pane_pictures.h`). A picture is due only after the tab's content changed (``note(_:now:)`` with
/// `.damaged`), at once after a quiet spell and then at most once a gap, one capture at a time, and never while no
/// card shows the tab. No clock and no timer here: the caller passes the time and arms one timer at the due time.
@MainActor
final class PanePictureSchedule {
    enum Event: UInt32 {
        case watched = 1
        case unwatched = 2
        case damaged = 3
    }

    enum Outcome: UInt32 {
        /// The picture was taken and kept.
        case done = 1
        /// The engine gave nothing; due again after a backoff.
        case failed = 2
        /// The tab cannot be pictured now (a hidden Chromium page): no retry until it changes or shows again.
        case unavailable = 3
    }

    /// A terminal's gap: its frame is one GPU blit off the main thread.
    static let terminalGap: UInt64 = UInt64(CMUX_PANE_PICTURES_TERMINAL_GAP_MS)
    /// A page's gap (a browser tab, a chat, a Markdown page): its capture costs the main thread a Chromium encode.
    static let pageGap: UInt64 = UInt64(CMUX_PANE_PICTURES_PAGE_GAP_MS)

    /// The Rust schedule; freed once, with its owner.
    private nonisolated final class Handle {
        let raw: OpaquePointer?
        init(_ raw: OpaquePointer?) { self.raw = raw }
        deinit { cmux_pane_pictures_schedule_free(raw) }
    }

    private let handle: Handle
    private var schedule: OpaquePointer? { handle.raw }

    init(gap: UInt64) { handle = Handle(cmux_pane_pictures_schedule_new(gap)) }

    /// Records `event`; returns when the next capture is due (ms), nil when none is.
    @discardableResult
    func note(_ event: Event, now: UInt64) -> UInt64? { Self.due(cmux_pane_pictures_schedule_note(schedule, event.rawValue, now)) }

    /// The generation a capture starts for now, when one is due; nil when none is.
    func takeDue(now: UInt64) -> UInt64? { Self.due(cmux_pane_pictures_schedule_take_due(schedule, now)) }

    /// A capture ``takeDue(now:)`` started for `generation` ended; returns when the next is due.
    @discardableResult
    func finish(_ generation: UInt64, _ outcome: Outcome, now: UInt64) -> UInt64? {
        Self.due(cmux_pane_pictures_schedule_finish(schedule, generation, outcome.rawValue, now))
    }

    /// The kept picture shows the tab as it is (no change since it was taken).
    var isCurrent: Bool { cmux_pane_pictures_schedule_is_current(schedule) }

    private static func due(_ raw: Int64) -> UInt64? { raw < 0 ? nil : UInt64(raw) }
}
