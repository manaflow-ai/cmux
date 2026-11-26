#if canImport(CCmuxPanePicturesFFI)
internal import CCmuxPanePicturesFFI
#endif

/// What happened to a tab, for its thumbnail schedule (cmux-pane-pictures `Event`).
public enum PanePictureEvent: UInt32 {
    /// A card shows the tab.
    case watched = 1
    /// No card shows the tab.
    case unwatched = 2
    /// The tab's content changed.
    case damaged = 3
}

/// How a capture ended (cmux-pane-pictures `Outcome`).
public enum PanePictureOutcome: UInt32 {
    /// The picture was kept.
    case done = 1
    /// The capture failed: the schedule retries after a backoff.
    case failed = 2
    /// Nothing to picture now (a blank page, a shell with only its prompt, a hidden page): no retry
    /// until the tab is damaged or watched again.
    case unavailable = 3
}

/// One tab's thumbnail schedule: when its picture must be captured again. The decision is
/// Rust's (cmux-tui/crates/cmux-pane-pictures, `PictureSchedule`); Swift only passes the clock.
/// Times are milliseconds of one monotonic clock; a returned due time in the past means now.
public protocol PanePictureScheduling: AnyObject {
    /// Records `event`; when a capture may start, nil when none is wanted.
    func note(_ event: PanePictureEvent, now: UInt64) -> UInt64?
    /// The generation a capture started now is of (now in flight), nil when none is due.
    func takeDue(now: UInt64) -> UInt64?
    /// A capture of `generation` ended; when the next may start, nil when none is wanted.
    @discardableResult
    func finish(_ generation: UInt64, _ outcome: PanePictureOutcome, now: UInt64) -> UInt64?
    /// The kept picture shows the tab's current content: a reopened card draws it with no capture.
    var isCurrent: Bool { get }
}

/// ``PanePictureScheduling`` over the Rust schedule's C ABI (cmux_pane_pictures.h).
public final class RustPanePictureSchedule: PanePictureScheduling {
    /// The gap between capture starts of a terminal tab (`CMUX_PANE_PICTURES_TERMINAL_GAP_MS`).
    public static let terminalGapMs: UInt64 = 200
    /// The gap between capture starts of a page tab (`CMUX_PANE_PICTURES_PAGE_GAP_MS`).
    public static let pageGapMs: UInt64 = 500

    /// Whether this build links the schedule (the pinned app FFI release carries CCmuxPanePicturesFFI).
    public static var isLinked: Bool {
        #if canImport(CCmuxPanePicturesFFI)
        true
        #else
        false
        #endif
    }

    #if canImport(CCmuxPanePicturesFFI)
    private let handle: OpaquePointer
    /// The handle's address, a plain value, so the nonisolated deinit can free it.
    private let handleAddress: UInt

    /// A new schedule (unwatched, undamaged, no picture) with `gapMs` between capture starts; nil
    /// when the library refuses one.
    public init?(gapMs: UInt64) {
        guard let handle = cmux_pane_pictures_schedule_new(gapMs) else { return nil }
        (self.handle, self.handleAddress) = (handle, UInt(bitPattern: handle))
    }

    nonisolated deinit { cmux_pane_pictures_schedule_free(OpaquePointer(bitPattern: handleAddress)) }

    public func note(_ event: PanePictureEvent, now: UInt64) -> UInt64? {
        Self.due(cmux_pane_pictures_schedule_note(handle, event.rawValue, now))
    }

    public func takeDue(now: UInt64) -> UInt64? {
        Self.due(cmux_pane_pictures_schedule_take_due(handle, now))
    }

    @discardableResult
    public func finish(_ generation: UInt64, _ outcome: PanePictureOutcome, now: UInt64) -> UInt64? {
        Self.due(cmux_pane_pictures_schedule_finish(handle, generation, outcome.rawValue, now))
    }

    public var isCurrent: Bool { cmux_pane_pictures_schedule_is_current(handle) }

    private static func due(_ raw: Int64) -> UInt64? {
        raw < 0 ? nil : UInt64(raw)  // NOT_DUE (or any refusal) is negative: never a trap
    }
    #else
    /// This build's app FFI predates the schedule: there is none, and pictures are taken as before.
    public init?(gapMs: UInt64) { nil }

    public func note(_ event: PanePictureEvent, now: UInt64) -> UInt64? { nil }
    public func takeDue(now: UInt64) -> UInt64? { nil }
    @discardableResult
    public func finish(_ generation: UInt64, _ outcome: PanePictureOutcome, now: UInt64) -> UInt64? { nil }
    public var isCurrent: Bool { false }
    #endif
}
