import Foundation

/// When the screen may hand queued session output to Ghostty (termfix r13 D1).
///
/// Ghostty renders on its own thread as soon as a batch is parsed. A program
/// that writes one update in two pieces (a row, then its live area redrawn
/// below it, as Codex and `stream20` do) reaches the phone as two chunks a
/// fraction of a millisecond apart. Fed one by one, the first piece is drawn
/// alone: a frame with the new row and no live area, the page one row off,
/// then the next frame puts it back (verifier 2026-10-19: 46 times in 66 s).
///
/// So a feed waits until the output has been quiet for `quiet`, or until the
/// oldest waiting chunk has waited `maxHold` (a steady flood still goes once
/// per frame). Bytes left over a frame's budget go at once.
public struct TerminalOutputBurst: Sendable, Equatable {
    /// Gap after the last chunk that ends a burst. Chunks of one Mac write
    /// arrive well inside it on a LAN or relay path.
    public static let quiet: TimeInterval = 0.003
    /// The longest any chunk waits for its burst to end.
    public static let maxHold: TimeInterval = 0.008

    /// When the oldest chunk not yet fed arrived.
    public private(set) var firstPending: TimeInterval?
    /// When the newest chunk arrived.
    public private(set) var lastArrival: TimeInterval?

    public init() {}

    public mutating func arrived(at now: TimeInterval) {
        if firstPending == nil { firstPending = now }
        lastArrival = now
    }

    /// The earliest time a feed may start, or nil when nothing waits.
    public var readyTime: TimeInterval? {
        guard let first = firstPending, let last = lastArrival else { return nil }
        return min(last + Self.quiet, first + Self.maxHold)
    }

    /// A feed may start now (nothing waits, or the burst ended).
    public func mayFeed(at now: TimeInterval) -> Bool {
        guard let ready = readyTime else { return true }
        return now >= ready - 0.0001
    }

    /// A batch was taken. With bytes still queued (over the frame's budget)
    /// the rest is a backlog: it goes on the next frame without a new wait.
    public mutating func fed(queueEmpty: Bool) {
        if queueEmpty {
            firstPending = nil
            lastArrival = nil
        } else {
            // Leave the times: the burst already ended, so `mayFeed` stays true.
        }
    }
}

/// The screen's feed gate: one batch with Ghostty at a time, at most one
/// started per display frame, and (r13 D1) never in the middle of a burst.
public struct TerminalFeedPacer: Sendable, Equatable {
    /// A batch is with Ghostty; the next waits for its completion.
    public private(set) var inFlight = false
    /// The next feed outside the display link waits until this time: the
    /// end of the display frame of the last feed.
    public var nextAllowed: TimeInterval = 0
    public private(set) var burst = TerminalOutputBurst()
    /// Off for A/B on the rig (`-CmuxMobileNoBurstHold`).
    public var holdsBursts: Bool

    public init(holdsBursts: Bool = true) {
        self.holdsBursts = holdsBursts
    }

    public mutating func arrived(at now: TimeInterval) { burst.arrived(at: now) }

    /// A batch may be handed to Ghostty now.
    public func canFeed(at now: TimeInterval) -> Bool {
        !inFlight && now >= nextAllowed && (!holdsBursts || burst.mayFeed(at: now))
    }

    /// When to look again if output waits only for its burst to end.
    public func wakeTime(at now: TimeInterval) -> TimeInterval? {
        guard holdsBursts, !inFlight, let ready = burst.readyTime, ready > now else { return nil }
        return max(ready, nextAllowed)
    }

    public mutating func started(frameEnd: TimeInterval, queueEmpty: Bool) {
        inFlight = true
        nextAllowed = frameEnd
        burst.fed(queueEmpty: queueEmpty)
    }

    public mutating func finished() { inFlight = false }

    /// The queue is empty and nothing is in flight (the last step may have
    /// been an alternate screen switch): the next chunk starts a new burst.
    public mutating func drained() {
        guard !inFlight else { return }
        burst.fed(queueEmpty: true)
    }

    /// A new display frame: one more batch may go.
    public mutating func newFrame() { nextAllowed = 0 }
}
