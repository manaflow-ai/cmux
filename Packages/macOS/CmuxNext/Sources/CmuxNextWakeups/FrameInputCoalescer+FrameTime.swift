public import CmuxNextInputCore

extension FrameInputCoalescer {
    /// A consumer whose `deliver` also gets the frame each delivery is drawn in
    /// (``frameTime(for:)``), for a drag that draws a resampled point: Chromium resamples at the
    /// `frame_time` of `DispatchRafAlignedInput` (main_thread_event_queue.cc).
    public func frameTimedConsumer(owner: String, lowLatency: Bool = false,
                                   deliver: @escaping @MainActor (PointerCoalescedInput, PointerFrameTime) -> Void) -> PointerFrameConsumer {
        PointerFrameConsumer(owner: owner, lowLatency: lowLatency, coalescer: self, deliver: deliver)
    }

    /// The frame `input` is delivered for: the running frame tick's time, or `input`'s newest event
    /// time when it goes out at once (no frame has begun for it).
    func frameTime(for input: PointerCoalescedInput) -> PointerFrameTime {
        if let tickTime { return PointerFrameTime(time: tickTime, interval: frameIntervalSeconds) }
        return PointerFrameTime(time: input.latest.timestamp, interval: frameIntervalSeconds)
    }
}
