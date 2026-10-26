import CmuxNextCompat
import GhosttyNextKit

/// Whether the program in one terminal has the mouse (it turned mouse reporting on), for the main
/// thread without the terminal's lock. `ghostty_surface_mouse_captured` takes the renderer-state mutex
/// that the output lane holds while it parses a chunk, and only parsed output turns reporting on or
/// off, so the lane asks it behind the output queued so far and the main thread reads the last answer.
///
/// The answer decides only whether a trackpad scroll waits for the frame (``TerminalPointerFrames``);
/// both routes give Ghostty the same scroll distance.
nonisolated final class TerminalMouseCapture: Sendable {
    private let lane: TerminalOutputLane?
    private let captured: Atomic<Bool>
    /// An ask is on the lane: a second one would give the same answer.
    private let asking = Atomic<Bool>(false)

    /// `lane` is the surface's output lane; with none (tests) the answer stays `captured`.
    init(lane: TerminalOutputLane?, captured: Bool = false) {
        self.lane = lane
        self.captured = Atomic(captured)
    }

    /// The program had the mouse after the output the lane parsed before the last answer.
    var programHasMouse: Bool { captured.load(ordering: .relaxed) }

    /// Asks again behind the output queued so far, unless an ask is already on the lane.
    func refresh() {
        guard let lane, !asking.exchange(true, ordering: .acquiringAndReleasing) else { return }
        lane.perform { [self] surface in
            captured.store(ghostty_surface_mouse_captured(surface), ordering: .relaxed)
            asking.store(false, ordering: .releasing)
        }
    }
}
