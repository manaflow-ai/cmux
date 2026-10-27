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
    /// Calls its argument with whether the program has the mouse, after the output queued so far.
    typealias Ask = @Sendable (_ answer: @escaping @Sendable (Bool) -> Void) -> Void

    private let ask: Ask?
    private let captured: Atomic<Bool>
    /// An ask is on the lane: a second one would give the same answer.
    private let asking = Atomic<Bool>(false)

    /// `lane` is the surface's output lane; with none the answer stays `captured`.
    convenience init(lane: TerminalOutputLane?, captured: Bool = false) {
        self.init(ask: lane.map { lane -> Ask in
            // SAFETY: the lane passes its live surface for the body's call only.
            { answer in unsafe lane.perform { surface in answer(unsafe ghostty_surface_mouse_captured(surface)) } }
        }, captured: captured)
    }

    /// `ask` gets the answer (the lane's, or a test's); with none the answer stays `captured`.
    init(ask: Ask?, captured: Bool = false) {
        self.ask = ask
        self.captured = Atomic(captured)
    }

    /// The program had the mouse after the output the lane parsed before the last answer.
    var programHasMouse: Bool { captured.load(ordering: .relaxed) }

    /// Asks again behind the output queued so far, unless an ask is already on the lane.
    func refresh() {
        guard let ask, !asking.exchange(true, ordering: .acquiringAndReleasing) else { return }
        ask { [self] hasMouse in
            captured.store(hasMouse, ordering: .relaxed)
            asking.store(false, ordering: .releasing)
        }
    }
}
