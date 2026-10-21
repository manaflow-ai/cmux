import Foundation

/// A mirror reset and its replay are one step for the screen (user report
/// 2026-10-14, "blinking and oscillating"). After a reset (`ESC c`: a
/// reattach, a resize), the Mac's replay of the whole history is fed to
/// Ghostty over several display frames. Laying the document out after each
/// batch showed the page passing through old history (the document grew from
/// the oldest rows) and black frames (the reset itself). The gate holds the
/// layout until the replay's bytes are all parsed; the screen keeps its last
/// frame meanwhile, then lays out once, at the bottom.
public struct TerminalReplayGate: Equatable, Sendable {
    /// A reset was seen and its replay is not parsed yet.
    public private(set) var isReplaying = false
    /// Replay bytes not parsed yet (nil: the replay has not arrived).
    private var remaining: Int?

    public init() {}

    /// How long a reset may gate the document (seconds).
    public static let deadline: TimeInterval = 2

    /// When the reset being replayed arrived (nil: none).
    private var resetAt: TimeInterval?

    /// A chunk of session output arrived (in order) at `now` (seconds, any clock).
    public mutating func received(_ count: Int, isReset: Bool, at now: TimeInterval) {
        if isReset { resetAt = now }
        received(count, isReset: isReset)
    }

    /// Ends a replay still gating at `now` past its deadline; true when it did.
    /// The gate's own deadline, whatever the held frame did: the held frame's
    /// timer is not armed for a reset during a scroll or while another frame
    /// is held, and a gate left on froze the page until the next drop (V3-2).
    public mutating func expireIfOverdue(at now: TimeInterval) -> Bool {
        guard isReplaying, let resetAt, now - resetAt >= Self.deadline - 0.001 else { return false }
        expire()
        return true
    }

    /// A chunk of session output arrived (in order).
    public mutating func received(_ count: Int, isReset: Bool) {
        if isReset {
            isReplaying = true
            remaining = nil
        } else if isReplaying, remaining == nil {
            // The replay follows its reset at once (the same attach event).
            remaining = count
        }
    }

    /// Ghostty parsed `count` session bytes; true when this finished the replay.
    public mutating func parsed(_ count: Int) -> Bool {
        guard isReplaying, let left = remaining else { return false }
        let now = left - count
        if now > 0 {
            remaining = now
            return false
        }
        isReplaying = false
        remaining = nil
        return true
    }

    /// Give up waiting (the held frame's cap): lay out what there is.
    public mutating func expire() {
        isReplaying = false
        remaining = nil
        resetAt = nil
    }
}
