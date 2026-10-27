import AppKit
import CmuxNextInput
public import CmuxNextWakeups

extension SidebarView {
    /// The windows' frame-aligned pointer input for the Now Playing card's scrubber (feature
    /// `pointerFrameDrags`): a scrub moves the played part on a frame interval's first drag event and once
    /// more at its frame, to the latest point. Nil: on every drag event.
    public var scrubFrameInput: FrameInputCoalescers? {
        get { nowPlayingCardView.scrubber.pointerFrames }
        set { nowPlayingCardView.scrubber.pointerFrames = newValue }
    }
}

/// The scrubber's drag, aligned to its window's frame as Chromium delivers rAF-aligned moves
/// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`): the press seeks at
/// once, a drag shows the latest point at most twice a frame, and the release lands the pending point
/// before it seeks (`ShouldFlushQueue`).
extension SidebarNowPlayingScrubber {
    override func mouseDragged(with event: NSEvent) {
        guard dragged != nil else { return }
        if let frameDrag, frameDrag.post(event) { return }
        scrub(to: event.locationInWindow)
    }

    /// The seconds under `windowPoint` on the track; nil without a length or a width.
    func seconds(at windowPoint: CGPoint) -> TimeInterval? {
        guard let duration = nowPlaying?.duration, duration > 0, bounds.width > 0 else { return nil }
        let x = convert(windowPoint, from: nil).x
        return duration * min(max(0, x / bounds.width), 1)
    }

    /// A press starts this drag's consumer on its window's coalescer (none without frames or a window).
    func beginFrameDrag() {
        frameDrag?.cancel()
        frameDrag = window.flatMap { pointerFrames?.coalescer(for: $0) }?.consumer(owner: "SidebarNowPlayingScrubber") { [weak self] input in
            self?.scrub(to: CGPoint(x: input.latest.location.x, y: input.latest.location.y))
        }
    }

    /// The release: the frame's pending point lands first, then the drag's consumer goes.
    func endFrameDrag() {
        frameDrag?.flush()
        frameDrag = nil
    }

    /// The played part follows a drag to `windowPoint`.
    private func scrub(to windowPoint: CGPoint) {
        guard dragged != nil, let seconds = seconds(at: windowPoint) else { return }
        dragged = seconds
        update()
    }
}
