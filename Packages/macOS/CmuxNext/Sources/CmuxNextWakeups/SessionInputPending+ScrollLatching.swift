public import AppKit

extension SessionInputPending {
    /// How long a dispatched scroll keeps its scroll sequence open: a scroll generated before then
    /// continues the sequence and does not count as pending; a later one begins a new sequence.
    ///
    /// Chrome's rules (`components/input/mouse_wheel_phase_handler.cc`): a wheel notch with no
    /// phase latches the next notches into one sequence for its latching transaction
    /// (`kDefaultMouseWheelLatchingTransaction`, 500 ms), and after a trackpad phase end it waits
    /// for momentum (100 ms), so a fling continues the gesture.
    ///
    /// ```swift
    /// let latching = SessionInputPending.ScrollLatching()
    /// latching.sequenceOpen(after: 10, phase: [], momentum: [])  // 10.5: a notch latches
    /// ```
    public struct ScrollLatching: Sendable, Equatable {
        /// How long a phase-less wheel notch latches the next ones into its sequence.
        public var wheelLatching: TimeInterval
        /// How long a trackpad phase end waits for its momentum.
        public var momentumWait: TimeInterval

        /// The windows, in seconds; the defaults are Chromium's wheel latching and momentum waits.
        public init(wheelLatching: TimeInterval = 0.5, momentumWait: TimeInterval = 0.1) {
            self.wheelLatching = wheelLatching
            self.momentumWait = momentumWait
        }

        /// Until when (seconds since boot) the sequence of a scroll dispatched at `timestamp`
        /// stays open:
        /// - began, changed or stationary, as phase or as momentum: until the gesture's end
        ///   (infinity);
        /// - phase ended with no momentum yet: ``momentumWait`` (a fling's momentum continues it);
        /// - no phase and no momentum (a mouse wheel notch): ``wheelLatching``;
        /// - may-begin, cancelled, or momentum ended: closed (`timestamp`): the next scroll begins
        ///   a sequence.
        public func sequenceOpen(after timestamp: TimeInterval, phase: NSEvent.Phase, momentum: NSEvent.Phase) -> TimeInterval {
            let running: NSEvent.Phase = [.began, .changed, .stationary]
            if !phase.isDisjoint(with: running) || !momentum.isDisjoint(with: running) { return .infinity }
            if momentum.isEmpty {
                if phase.isEmpty { return timestamp + wheelLatching }
                if phase.contains(.ended) { return timestamp + momentumWait }
            }
            return timestamp
        }
    }
}
