public import AppKit

/// The app's scroll frame sequences (``FrameSequenceTracker/Interaction/scroll``), on the scheduler of the window a
/// scroll began in. A scroll is one sequence while its events latch into one scroll, by Chrome's rules
/// (`MouseWheelPhaseHandler`, content/browser/renderer_host/input/mouse_wheel_phase_handler.cc, through
/// ``SessionInputPending/ScrollLatching``):
/// - a trackpad or Magic Mouse gesture from its first event to its momentum's end, so one flick is one sequence:
///   after the gesture's `ended` the sequence waits ``SessionInputPending/ScrollLatching/momentumWait`` for momentum
///   (`kMaximumTimeBetweenPhaseEndedAndMomentumPhaseBegan`);
/// - a discrete mouse wheel's ticks until none comes for ``SessionInputPending/ScrollLatching/wheelLatching``
///   (`kDefaultMouseWheelLatchingTransaction`, where Chrome's phase handler sends the scroll end).
///
/// Chrome starts the scroll tracker at that scroll begin and stops it at its end
/// (`FrameSequenceTrackerCollection::StartScrollSequence`, cc/metrics/frame_sequence_tracker_collection.cc). The
/// timeouts close on the open scheduler's own frame ticks (it ticks anyway while the sequence is open), and a later
/// scroll past a timeout no tick reached closes the stale sequence first.
///
/// Every scroll the app dispatches reaches it through the input dispatch context (`sendEvent` and `debug.mouse`
/// alike). A cancelled gesture, a touch that may begin one, or a mouse button ends an open sequence, so a gesture
/// whose end never came does not keep its window ticking.
@MainActor
public final class ScrollFrameSequences {
    private let latching: SessionInputPending.ScrollLatching
    private let schedulerOf: @MainActor (NSWindow) -> FrameScheduler
    /// The scheduler whose scroll sequence is open, nil while none is.
    private weak var open: FrameScheduler?
    /// When (seconds since boot) the open sequence closes if no scroll comes: infinity while a gesture runs.
    private var closesAt: TimeInterval = 0
    /// Closes the open sequence on the first of its scheduler's frames at or past ``closesAt``.
    private var timeout: FrameClient?

    /// - Parameters:
    ///   - latching: How long a wheel tick and a gesture's end keep the sequence open (Chrome's by default).
    ///   - schedulerOf: The scheduler a scroll in a window counts on (by default its top-level window's: a Chromium
    ///     page window or the overlay panel scrolls for the window it is a child of).
    public init(latching: SessionInputPending.ScrollLatching = .init(),
                schedulerOf: @escaping @MainActor (NSWindow) -> FrameScheduler = { FrameScheduler.forWindow(ScrollFrameSequences.topLevel($0)) }) {
        self.latching = latching
        self.schedulerOf = schedulerOf
    }

    /// A scroll sequence is open.
    public var isOpen: Bool { open != nil }

    /// A dispatched scroll or button event and the window it was dispatched to (`event.window`, nil for a
    /// synthesized scroll, unless the dispatcher names one).
    public func note(_ event: NSEvent, in window: NSWindow?) {
        guard event.type == .scrollWheel else { return end() }
        note(phase: event.phase, momentumPhase: event.momentumPhase, at: event.timestamp,
             scheduler: (window ?? event.window).map(schedulerOf))
    }

    /// One scroll event: its gesture `phase` and `momentumPhase`, its `timestamp` (seconds since boot), and the
    /// scheduler of its window, read only when the event may open a sequence. A begin on another scheduler (the
    /// gesture moved windows, or its end was lost) ends the open sequence first.
    public func note(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, at timestamp: TimeInterval,
                     scheduler: @autoclosure () -> FrameScheduler?) {
        if open != nil, timestamp >= closesAt { end() }
        let until = latching.sequenceOpen(after: timestamp, phase: phase, momentum: momentumPhase)
        guard until > timestamp else { return end() }
        // A running gesture or a wheel tick opens one; a gesture's end only keeps an open one waiting for momentum.
        let mayStart = open == nil ? until == .infinity || (phase.isEmpty && momentumPhase.isEmpty)
                                   : phase.contains(.began) || momentumPhase.contains(.began)
        if mayStart, let target = scheduler(), target !== open {
            end()
            start(on: target)
        }
        if open != nil { closesAt = until }
    }

    /// Ends the open sequence (nothing while none is).
    public func end() {
        timeout?.deactivate()
        timeout = nil
        guard let scheduler = open else { return }
        open = nil
        scheduler.endSequence(.scroll)
    }

    private func start(on scheduler: FrameScheduler) {
        scheduler.beginSequence(.scroll)
        open = scheduler
        let timeout = FrameClient(owner: "ScrollFrameSequences", isAnimation: false, on: scheduler) { [weak self] tick in
            self?.frame(at: tick.timestamp) ?? false
        }
        self.timeout = timeout
        timeout.activate()
    }

    /// A frame of the open scheduler: past ``closesAt`` the sequence ends (false: no more ticks).
    private func frame(at timestamp: CFTimeInterval) -> Bool {
        guard open != nil else { return false }
        guard timestamp >= closesAt else { return true }
        end()
        return false
    }

    /// The top-level window `window` belongs to.
    public static func topLevel(_ window: NSWindow) -> NSWindow {
        var top = window
        while let parent = top.parent { top = parent }
        return top
    }
}
