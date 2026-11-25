#if canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
#endif
import Foundation

/// One link's last progress (Rust `cmux_composer_send::progress`, `LinkProgressClock`): every
/// wait on the send path is bounded by silence since the later of its start and this, not by a
/// fixed time from its start (Leo, 2026-11-24: "10s timeout for messages being sendsble is a
/// shame. if it's making good progress, it shiukd be allowed to keep going?").
///
/// One per Mac link (``MacSession/progress``), and one per channel whose stall must not hide
/// behind the link's other traffic (the terminal's input lane). Swift only tells it what it read
/// (bytes heard, a write taken, an answer, the link reaching a step) and asks Rust's verdict; the
/// transport can report into the same ``progressed()`` later.
public final class LinkProgress: Sendable {
    #if canImport(CmuxMobileLinkFFI)
    private let clock = LinkProgressClock()
    #endif
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    /// This clock's now, in its milliseconds.
    public func nowMs() -> UInt64 { ChatPromptClock.milliseconds(now()) }

    /// The link made progress now.
    public func progressed() {
        #if canImport(CmuxMobileLinkFFI)
        clock.progressed(nowMs: nowMs())
        #endif
    }

    /// A wait begun at `startedMs` (``nowMs()``) and bounded by `stall` of silence: how much more
    /// silence it may take (look again then), or nil once it stalled.
    public func stallLeft(startedMs: UInt64, stall: Duration) -> Duration? {
        #if canImport(CmuxMobileLinkFFI)
        guard let left = clock.stallLeftMs(startedMs: startedMs, stallMs: ChatPromptClock.milliseconds(stall), nowMs: nowMs()) else { return nil }
        return .milliseconds(Int(clamping: left))
        #else
        // Without Rust: the old fixed bound from the start.
        let elapsed = nowMs() &- startedMs
        let bound = ChatPromptClock.milliseconds(stall)
        return elapsed < bound ? .milliseconds(Int(clamping: bound - elapsed)) : nil
        #endif
    }

    /// For ``LinkDeadline/run(timeout:timeoutError:extend:operation:onCancel:onDiscard:)``,
    /// ``ObservationWait`` and the terminal's lane waits: the wait begun now, bounded by `stall`.
    public func stallExtension(after stall: Duration) -> @Sendable () -> Duration? {
        let started = nowMs()
        return { [self] in stallLeft(startedMs: started, stall: stall) }
    }

    /// Seconds since the link's last progress, if it made any.
    public func lastProgressAge() -> TimeInterval? {
        #if canImport(CmuxMobileLinkFFI)
        guard let last = clock.lastProgressMs() else { return nil }
        let now = nowMs()
        return now > last ? TimeInterval(now - last) / 1000 : 0
        #else
        return nil
        #endif
    }
}
