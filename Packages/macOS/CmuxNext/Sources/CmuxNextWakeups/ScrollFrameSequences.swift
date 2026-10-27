public import AppKit

/// The app's scroll frame sequences (``FrameSequenceTracker/Interaction/scroll``): a trackpad or Magic Mouse scroll
/// gesture is one sequence from its `began` phase to its `ended` or `cancelled` phase, and the momentum after it is
/// another, from momentum `began` to momentum `ended`, on the scheduler of the window the gesture began in. Chrome
/// does the same in the compositor: scroll begin starts a scroll sequence and scroll end stops it
/// (`FrameSequenceTrackerCollection::StartScrollSequence`, cc/metrics/frame_sequence_tracker_collection.cc, called
/// from cc/input/input_handler.cc); a fling is part of it there, and here the two halves carry into one
/// `smoothness.dropped_pct.scroll` sample when short.
///
/// A terminal scroll and a page scroll (WebKit or an in-process Chromium page window) both reach it, since every
/// scroll event the app dispatches passes the input tap (`AppServices`). A wheel tick with no phase has no gesture
/// end to close a sequence, so it opens none; a mouse button ends an open one, so a gesture whose end never came
/// does not keep its window ticking.
@MainActor
public final class ScrollFrameSequences {
    /// The scheduler whose scroll sequence is open, nil while none is.
    private weak var open: FrameScheduler?

    public init() {}

    /// A scroll sequence is open.
    public var isOpen: Bool { open != nil }

    /// A dispatched scroll or button event; a scroll counts on the scheduler of its top-level window (a Chromium
    /// page window or the overlay panel scrolls for the window it is a child of).
    public func note(_ event: NSEvent) {
        guard event.type == .scrollWheel else { return end() }
        note(phase: event.phase, momentumPhase: event.momentumPhase, scheduler: event.window.map { FrameScheduler.forWindow(Self.topLevel($0)) })
    }

    /// One scroll event: its gesture `phase` and `momentumPhase`, and the scheduler of its window (read only when
    /// the event begins a sequence). A begin while one is open (its end was lost) ends that one first.
    public func note(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, scheduler: @autoclosure () -> FrameScheduler?) {
        if phase.contains(.began) || momentumPhase.contains(.began) {
            end()
            guard let scheduler = scheduler() else { return }
            scheduler.beginSequence(.scroll)
            open = scheduler
        } else if !phase.isDisjoint(with: [.ended, .cancelled]) || !momentumPhase.isDisjoint(with: [.ended, .cancelled]) {
            end()
        }
    }

    /// Ends the open sequence (nothing while none is).
    public func end() {
        guard let scheduler = open else { return }
        open = nil
        scheduler.endSequence(.scroll)
    }

    private static func topLevel(_ window: NSWindow) -> NSWindow {
        var top = window
        while let parent = top.parent { top = parent }
        return top
    }
}
