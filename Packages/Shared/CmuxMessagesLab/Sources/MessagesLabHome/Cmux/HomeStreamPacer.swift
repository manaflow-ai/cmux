/// At most one streamed-text commit per display frame (plans/cmux-next/home-streaming-perf-DESIGN.md, 1).
///
/// The screen shows one state per frame, and a reply's tokens come faster than
/// that (in bursts, 50-200 a second): every stream commit after the first in a
/// frame is main-thread work nobody sees, and input waits behind it. A
/// stream-only update (the live text changed, nothing else did) commits at once
/// when it is the frame's first; a later one in the same frame, or one in a
/// frame a keystroke opened, waits for the next frame's start, where one
/// refresh reads the newest text (latest wins, nothing is dropped). The refresh
/// at a frame's start always commits, so typing in every frame never starves
/// the stream: it shows one frame later at most.
///
/// A transcript, summary or typing change never waits here.
final class HomeStreamPacer {
    /// A stream update committed in the current display frame.
    private(set) var committedThisFrame = false
    /// A refresh is due at the next frame's start.
    private(set) var pending = false
    /// The frame-start callback is registered.
    private var hooked = false
    /// Inside the frame-start refresh (it always commits).
    private var atFrameStart = false
    /// Counts for tests: commits admitted, updates held for a later frame, updates merged into a pending refresh.
    private(set) var commits = 0, held = 0, merged = 0

    /// Whether a stream-only update may commit now. When not, `refresh` runs at the next frame's start.
    /// - Parameter inputFrame: a keystroke went ahead in this frame (`ChatController.inKeystrokeFrame`).
    /// - Parameter nextFrame: runs work at the start of the next display frame (`ChatController.nextFrame`).
    /// - Parameter refresh: the projection's refresh, which reads the newest text.
    func admit(inputFrame: Bool, nextFrame: (@escaping () -> Void) -> Void, refresh: @escaping () -> Void) -> Bool {
        if atFrameStart {
            committedThisFrame = true
            commits += 1
            hook(nextFrame, refresh) // the frame's flag clears at the next start
            return true
        }
        if pending { merged += 1; return false }
        if committedThisFrame || inputFrame {
            pending = true
            held += 1
            hook(nextFrame, refresh)
            return false
        }
        committedThisFrame = true
        commits += 1
        hook(nextFrame, refresh)
        return true
    }

    /// Commits a held stream update now (`refresh` reads the newest text and is admitted): a send
    /// orders itself after the reply as the person saw it last, never after a text one frame old.
    /// Does nothing when no update is held.
    func flush(_ refresh: () -> Void) {
        guard pending else { return }
        pending = false
        atFrameStart = true
        defer { atFrameStart = false }
        refresh()
    }

    private func hook(_ nextFrame: (@escaping () -> Void) -> Void, _ refresh: @escaping () -> Void) {
        guard !hooked else { return }
        hooked = true
        nextFrame { [weak self] in
            guard let self else { return }
            self.hooked = false
            self.committedThisFrame = false
            guard self.pending else { return }
            self.pending = false
            self.atFrameStart = true
            defer { self.atFrameStart = false }
            refresh()
        }
    }
}
