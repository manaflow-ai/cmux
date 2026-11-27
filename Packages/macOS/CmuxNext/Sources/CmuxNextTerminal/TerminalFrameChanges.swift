import CmuxNextCompat

/// Counts a terminal's content changes (every event of its IO: output, a replay, a snapshot, a resize), from any thread,
/// so the launch frame keeper (``TerminalLaunchFrameKeeper``) saves a frame only after a change and never per keystroke:
/// the first change after the keeper's last read tells it once; later ones only count until it reads again.
public nonisolated final class TerminalFrameChanges: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var onChange: (@Sendable () -> Void)?
        var told = false
    }

    private let state = Mutex(State())

    public init() {}

    /// The changes so far.
    public var generation: UInt64 { state.withLock { $0.generation } }

    /// One change. Tells the observer only on the first change since its last ``take()``.
    func bump() { // perf-hot: 0.2us terminal-key (every output chunk of every terminal, off the main thread)
        let tell = state.withLock { state -> (@Sendable () -> Void)? in
            state.generation &+= 1
            guard !state.told, let onChange = state.onChange else { return nil }
            state.told = true
            return onChange
        }
        tell?()
    }

    /// A change of whether the terminal shows (shown, hidden, drawn, paused, closed): tells the observer even when it
    /// already was told and has not read since. A hidden terminal's keeper does not read after its hide (SWITCH FRAMES
    /// SF-5: a read re-armed the tell, so every hidden output chunk woke the main actor about twice a second), so
    /// output while hidden only counts; the next visibility change wakes it.
    func wake() {
        let tell = state.withLock { state -> (@Sendable () -> Void)? in
            state.generation &+= 1
            state.told = state.onChange != nil
            return state.onChange
        }
        tell?()
    }

    /// The changes so far; the next change tells the observer again.
    func take() -> UInt64 {
        state.withLock { state in
            state.told = false
            return state.generation
        }
    }

    /// `onChange` runs (on the changing thread) at the first change after each ``take()``.
    func observe(_ onChange: @escaping @Sendable () -> Void) {
        state.withLock { state in
            state.onChange = onChange
            state.told = false
        }
    }
}
