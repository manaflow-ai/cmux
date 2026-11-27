#if DEBUG || CMUX_BENCH_HOOKS
public import CoreGraphics

/// Plays ``DebugKeySequence``s (DEBUG builds): one task posts every step in order at its offset, on an
/// injected clock, and a new sequence cancels the one playing.
///
/// The app makes one at its control composition (`AppControl`) and posts to its own event queue; tests
/// make their own with a test clock and collect the events:
///
/// ```swift
/// let player = DebugKeySequencePlayer()
/// await player.play(sequence, stamp: stamp, source: nil, clock: ContinuousClock()) { events.append($0) }.value
/// ```
@MainActor public final class DebugKeySequencePlayer {
    private var playing: Task<Void, Never>?

    /// Whether a sequence is still posting (`debug.burst status` reports it to the burst bench).
    public var isPlaying: Bool { playing != nil }

    /// A player with nothing playing.
    public init() {}

    /// Cancels the sequence playing, if any, and plays `sequence`: each step's event, stamped with its
    /// intended press time, goes to `post` at its offset from now on `clock`.
    ///
    /// - Parameters:
    ///   - sequence: The planned steps.
    ///   - stamp: The sequence's start in the event system's clock.
    ///   - source: The event source the events are made from.
    ///   - clock: The clock the offsets run on (tests pass their own).
    ///   - post: Where each event goes (the app's event queue).
    /// - Returns: The task that plays it; it ends after the last step, or when the next sequence
    ///   cancels it (then it posts nothing more).
    @discardableResult
    public func play<C: Clock<Duration>>(_ sequence: DebugKeySequence, stamp: DebugKeySequence.Stamp, source: CGEventSource?,
                                         clock: C, post: @escaping @MainActor (CGEvent) -> Void) -> Task<Void, Never> {
        playing?.cancel()
        let start = clock.now
        let task = Task { @MainActor [weak self] in
            for step in sequence.steps {
                // wakeup-allow: each sleep is the next step's own deadline in the sequence (bounded by its gaps, cancelled by the next sequence), not a poll
                // Zero tolerance: each event carries its intended time, so timer leeway would count as the app's input age.
                do { try await clock.sleep(until: start.advanced(by: step.offset), tolerance: .zero) } catch { return }
                // A clock whose sleep ignores cancellation must not let a replaced sequence post on.
                guard !Task.isCancelled else { return }
                guard let event = sequence.event(step, stamp: stamp, source: source) else { continue }
                post(event)
            }
            // Not cancelled, so still the sequence playing: a new one cancels this task before it plays.
            guard !Task.isCancelled else { return }
            self?.playing = nil
        }
        playing = task
        return task
    }
}
#endif
