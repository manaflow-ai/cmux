import AppKit
import CmuxNextInput

// The space bar's hover once per frame (feature `pointerFrameHover`, p04-input-033): with
// `hoverFrameInput`, a frame interval's first move hovers at once and the rest once at its frame, at
// the latest point (Chromium's rAF-aligned moves, main_thread_event_queue.cc); each at once without it.
extension ProfileBarView {
    /// The windows' frame-aligned pointer input; nil: each move hovers at once.
    var hoverFrameInput: PointerFrameCoalescers? {
        get { hoverMoves.frames }
        set { hoverMoves.frames = newValue }
    }

    override func mouseMoved(with event: NSEvent) { hoverMoves.moved(event) }

    /// Hovers the space under `windowPoint`, hit-tested where the slots are now.
    func hover(atWindowPoint windowPoint: NSPoint) { setHovered(index(at: convert(windowPoint, from: nil))) }
}
