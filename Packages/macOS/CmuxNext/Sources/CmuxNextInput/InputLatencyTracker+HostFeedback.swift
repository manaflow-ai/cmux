public import CmuxNextInputCore
public import Foundation

/// A Chromium page's presentation feedback. A page in its own host process shows its input in a frame
/// cmux does not commit; the host reports when that frame reached the display, by the input's event time, as the viz
/// presentation feedback of a renderer's frame closes its events' `EventMetrics` in Chrome
/// (cc/metrics/compositor_frame_reporter.cc, `DidPresentCompositorFrame`; `gfx::PresentationFeedback` in
/// ui/gfx/presentation_feedback.h). The event time is the id both sides share: the page view sends it as the input
/// frame's `t0` (``InputLatencyTracker/eventNanos(_:)``) and the slot keeps it as its `generated` stage.
extension InputLatencyTracker {
    /// Closes the open Chromium page slot of the input whose event time is `eventNanos` at `presentedNanos`, the time
    /// the page's host reported for the frame that shows it: source ``InputPresentationSource/hostFeedback``. The
    /// oldest open page slot with that `generated` time is the input's. A slot still in its turn gets the time now and
    /// closes at the turn's commit; one past it closes at once.
    ///
    /// A report that matches no open page slot (the slot closed at ``contentDeadlineNanos`` first, its input was not
    /// tracked, or the time is before the event) changes nothing and is counted in ``unmatchedHostPresentations``; one
    /// that comes after the slot's deadline closes it with no presented time and is counted too.
    ///
    /// - Parameters:
    ///   - eventNanos: The input's event time (`CLOCK_UPTIME_RAW` nanoseconds), as its input frame carried it.
    ///   - presentedNanos: When the frame that shows it reached the display (`CLOCK_UPTIME_RAW` nanoseconds).
    /// - Returns: Whether a slot took the time.
    @discardableResult
    public func hostPresented(eventNanos: UInt64, at presentedNanos: UInt64) -> Bool {
        guard eventNanos != 0, presentedNanos >= eventNanos else { return unmatchedHostPresentation() }
        if let index = waiting.firstIndex(where: { isPage($0.token, $0.target, generatedAt: eventNanos) }) {
            let entry = waiting.remove(at: index)
            // Past the deadline the slot is a no-echo slot, as a late `contentSubmitted` makes it.
            let stamped = presentedNanos <= entry.deadline && stampHostPresented(entry.token, at: presentedNanos)
            close(entry.token, presented: nil)
            return stamped || unmatchedHostPresentation()
        }
        // In its turn still: the commit moves it to the waiting list, whose check closes it with the stamped time.
        if let entry = pending.first(where: { isPage($0.token, $0.target, generatedAt: eventNanos) }),
           stampHostPresented(entry.token, at: presentedNanos) {
            return true
        }
        return unmatchedHostPresentation()
    }

    /// An event's timestamp (`NSEvent.timestamp`, seconds since boot) in `CLOCK_UPTIME_RAW` nanoseconds, or 0 when it
    /// has none: the `generated` stage of its slot, and the event time a surface sends with the input (a Chromium
    /// host's `t0`), so a later report by that time finds the slot (``hostPresented(eventNanos:at:)``).
    public nonisolated static func eventNanos(_ timestamp: TimeInterval) -> UInt64 {
        timestamp > 0 ? UInt64((timestamp * 1_000_000_000).rounded()) : 0
    }

    private func isPage(_ token: InputLatencyToken, _ target: InputTarget, generatedAt nanos: UInt64) -> Bool {
        target == .chromiumPage && table.time(token, .generated) == nanos
    }

    private func stampHostPresented(_ token: InputLatencyToken, at nanos: UInt64) -> Bool {
        guard table.mark(token, .presented, at: nanos) else { return false }
        table.setPresentationSource(token, .hostFeedback)
        return true
    }

    private func unmatchedHostPresentation() -> Bool {
        unmatchedHostPresentations &+= 1
        return false
    }
}
