import CmuxNextCompat

/// Counts a terminal's content changes (every event of its IO: output, a replay, a snapshot, a resize), from any thread,
/// so the launch frame keeper (``TerminalLaunchFrameKeeper``) saves a frame only after a change and never per keystroke:
/// the first change after the keeper's last read tells it once; later ones only count until it reads again.
public nonisolated final class TerminalFrameChanges: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var onChange: (@Sendable () -> Void)?
        var told = false
        /// A shown hover card's watch (``watch(_:)``): told like ``onChange``, on its own edge.
        var onWatch: (@Sendable () -> Void)?
        var watchTold = false
        /// The changes when the watch was last told.
        var toldAt: UInt64 = 0

        /// The watch to tell for this change, once per ``rearmWatch()``.
        mutating func watchToTell() -> (@Sendable () -> Void)? {
            guard !watchTold, let onWatch else { return nil }
            watchTold = true
            toldAt = generation
            return onWatch
        }
    }

    private let state = Mutex(State())

    public init() {}

    /// The changes so far.
    public var generation: UInt64 { state.withLock { $0.generation } }

    /// One change. Tells the observer only on the first change since its last ``take()``.
    func bump() { // perf-hot: 0.2us terminal-key (every output chunk of every terminal, off the main thread)
        let (tell, watch) = state.withLock { state -> ((@Sendable () -> Void)?, (@Sendable () -> Void)?) in
            state.generation &+= 1
            let watch = state.watchToTell()
            guard !state.told, let onChange = state.onChange else { return (nil, watch) }
            state.told = true
            return (onChange, watch)
        }
        tell?()
        watch?()
    }

    /// A change of whether the terminal shows (shown, hidden, drawn, paused, closed): tells the observer even when it
    /// already was told and has not read since. A hidden terminal's keeper does not read after its hide (SWITCH FRAMES
    /// SF-5: a read re-armed the tell, so every hidden output chunk woke the main actor about twice a second), so
    /// output while hidden only counts; the next visibility change wakes it.
    func wake() {
        let (tell, watch) = state.withLock { state -> ((@Sendable () -> Void)?, (@Sendable () -> Void)?) in
            state.generation &+= 1
            state.told = state.onChange != nil
            return (state.onChange, state.watchToTell())
        }
        tell?()
        watch?()
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

    /// A hover card shows this terminal's picture (#51768): `onWatch` runs (on the changing thread) at the first change
    /// after this call and after each ``rearmWatch()``, so a streaming terminal wakes the card once per rearm, not once
    /// per output chunk, and a terminal no card shows costs one more nil check per change. Replaces any earlier watch.
    public func watch(_ onWatch: @escaping @Sendable () -> Void) {
        state.withLock { state in
            state.onWatch = onWatch
            state.watchTold = false
        }
    }

    /// The watch is told again at the next change. Returns whether the content changed again after the watch was
    /// last told: that change's frame may not have shown yet, so the caller asks for one more picture after it does.
    @discardableResult
    public func rearmWatch() -> Bool {
        state.withLock { state in
            let moved = state.watchTold && state.generation != state.toldAt
            state.watchTold = false
            return moved
        }
    }

    /// The card stopped showing this terminal: changes only count again.
    public func stopWatching() {
        state.withLock { state in
            state.onWatch = nil
            state.watchTold = false
        }
    }
}
