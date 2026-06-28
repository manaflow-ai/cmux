public import Foundation

/// Drives the directional-pad ("arrow nub") key-repeat cadence with a bounded,
/// cancellable task and an injected `Clock`, replacing the gesture-driven
/// `Timer.scheduledTimer` the UIKit nub used.
///
/// The arrow nub fires one arrow sequence the instant a direction is engaged,
/// then repeats it on a fixed interval while the drag holds that direction.
/// Modeling that as an injected-clock task instead of a `Timer` makes the
/// cadence virtual-time testable and ties cancellation to the gesture lifecycle:
/// the caller starts a stream when a direction engages and cancels it (or starts
/// a new direction) on drag change/end, with no run-loop-coupled timer to leak.
///
/// The service is pure scheduling. It yields the encoded VT bytes for the
/// requested direction (via ``TerminalKeyEncoder``) on an `AsyncStream`; the UI
/// host consumes the stream and forwards the bytes to the transport.
///
/// The same injected-clock cadence also backs the hardware-keyboard
/// hold-to-repeat (``repeats(of:initialDelay:every:clock:)``), so neither the
/// nub nor the keyboard input view carries a hand-rolled `Task.sleep` loop.
///
/// ```swift
/// let service = TerminalArrowRepeatService()
/// let stream = service.repeats(of: .upArrow, every: .milliseconds(80), clock: ContinuousClock())
/// for await bytes in stream { transport.send(bytes) }   // cancel the task to stop
/// ```
public struct TerminalArrowRepeatService: Sendable {
    /// Creates an arrow-repeat service. Stateless; one instance can drive any
    /// number of independent repeat streams.
    public init() {}

    /// The arrow directions the nub can repeat.
    public enum Direction: Sendable {
        /// Up arrow (`ESC [ A`).
        case upArrow
        /// Down arrow (`ESC [ B`).
        case downArrow
        /// Left arrow (`ESC [ D`).
        case leftArrow
        /// Right arrow (`ESC [ C`).
        case rightArrow

        /// The platform-neutral key this direction maps to for byte encoding.
        var specialKey: TerminalSpecialKey {
            switch self {
            case .upArrow: return .upArrow
            case .downArrow: return .downArrow
            case .leftArrow: return .leftArrow
            case .rightArrow: return .rightArrow
            }
        }

        /// The exact VT bytes for this arrow (no modifiers), e.g. `ESC [ A`.
        public var bytes: Data {
            TerminalKeyEncoder.encode(specialKey: specialKey, modifiers: []) ?? Data()
        }
    }

    /// An `AsyncStream` of arrow bytes for `direction`: one immediate emission,
    /// then one every `interval` until the consuming task is cancelled.
    ///
    /// Cancellation is the only stop signal. The UI host wires the consuming
    /// task's cancellation to the gesture ending (or to engaging a different
    /// direction), so the repeat cadence ends exactly with the gesture.
    ///
    /// - Parameters:
    ///   - direction: The arrow to repeat.
    ///   - interval: The delay between repeats. The first emission is immediate.
    ///   - clock: The clock that paces the repeats. Injected so tests pace it
    ///     with virtual time.
    /// - Returns: A stream that yields the direction's VT bytes on the cadence.
    public func repeats<C: Clock>(
        of direction: Direction,
        every interval: C.Duration,
        clock: C
    ) -> AsyncStream<Data> where C.Duration == Duration {
        let bytes = direction.bytes
        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(bytes)
                while !Task.isCancelled {
                    do {
                        // Bounded, cancellable wait through the injected clock —
                        // the sanctioned Clock.sleep carve-out, paced in virtual
                        // time by tests, cancelled when the gesture ends.
                        try await clock.sleep(for: interval)
                    } catch {
                        break
                    }
                    if Task.isCancelled { break }
                    continuation.yield(bytes)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// An `AsyncStream` of arbitrary `bytes`: the FIRST emission only after
    /// `initialDelay`, then one every `interval` until the consuming task is
    /// cancelled.
    ///
    /// This is the hardware-key *hold-to-repeat* primitive, and its cadence
    /// deliberately differs from the arrow nub's ``repeats(of:every:clock:)``:
    /// the press site emits the first keystroke synchronously, so this stream
    /// stays SILENT for `initialDelay` — the leading "hold before repeat" pause a
    /// hardware keyboard applies — and only then begins the fast repeat, versus
    /// the nub's immediate first emission. It also repeats any captured byte block
    /// (an arrow, `Ctrl-C`, `Tab`, …), not just an arrow ``Direction``.
    ///
    /// As with the arrow stream, cancellation is the only stop signal: the UI host
    /// wires the consuming task's cancellation to the physical key's release
    /// (`pressesEnded`/`pressesCancelled`) or to focus loss.
    ///
    /// - Parameters:
    ///   - bytes: The encoded VT byte block to repeat while the key is held.
    ///   - initialDelay: The quiet "hold before repeat" delay before the first
    ///     emission. The synchronous press already sent the keystroke once.
    ///   - interval: The delay between repeats once repeating has begun.
    ///   - clock: The clock that paces the delays. Injected so tests pace it with
    ///     virtual time.
    /// - Returns: A stream that yields `bytes` on the typematic cadence.
    public func repeats<C: Clock>(
        of bytes: Data,
        initialDelay: C.Duration,
        every interval: C.Duration,
        clock: C
    ) -> AsyncStream<Data> where C.Duration == Duration {
        AsyncStream { continuation in
            let task = Task {
                do {
                    // Quiet leading delay before the key starts repeating — the
                    // sanctioned injected-clock sleep, cancelled the instant the
                    // key is released, paced in virtual time by tests.
                    try await clock.sleep(for: initialDelay)
                } catch {
                    continuation.finish()
                    return
                }
                while !Task.isCancelled {
                    continuation.yield(bytes)
                    do {
                        try await clock.sleep(for: interval)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
