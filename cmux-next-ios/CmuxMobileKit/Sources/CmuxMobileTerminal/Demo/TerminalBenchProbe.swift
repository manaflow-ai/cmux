// DEBUG and Demo builds only: the flood benchmark's probe is never compiled into Production.
#if DEBUG
import Foundation
import QuartzCore

/// DEBUG only. Measurement hooks for the terminal flood benchmark
/// (`TerminalFloodBench` in CmuxMobileLive, `verify/terminal-flood.md`). The
/// terminal screen reports raw session bytes Ghostty finished processing and
/// presented frames; the benchmark's fake daemon reports the stream offset
/// of each keystroke echo. An echo's latency is from the keystroke (taken
/// off the main thread, like a touch) to the first frame presented after
/// Ghostty processed the echo's bytes. Inactive (`shared == nil`) outside
/// the benchmark.
public final class TerminalBenchProbe: @unchecked Sendable {
    nonisolated(unsafe) public static var shared: TerminalBenchProbe?

    private let lock = NSLock()
    private var processed = 0
    private var presents = 0
    /// Keystrokes taken but not yet echoed by the fake daemon.
    private var keystrokes: [CFTimeInterval] = []
    /// Echoes in the stream: the session byte offset that ends them, and their keystroke times.
    private var echoes: [(end: Int, keys: [CFTimeInterval])] = []
    /// Echoes processed by Ghostty, waiting for the next presented frame.
    private var awaitingPresent: [CFTimeInterval] = []
    private var latencies: [Double] = []
    /// Milliseconds between consecutive presented frames, handed over by `take()`.
    private var frameIntervals: [Double] = []
    private var lastPresent: CFTimeInterval?
    /// The drain being timed: the stream offset to reach and when it started.
    private var drainTarget: (end: Int, since: CFTimeInterval)?
    /// Milliseconds from the drain's start until Ghostty processed its offset.
    private var drainMs: Double?

    public init() {}

    /// Times the drain: from `since` until Ghostty has processed session byte
    /// `end`, read back as ``Snapshot/drainMs``. Already there: zero.
    public func timeDrain(until end: Int, since: CFTimeInterval) {
        lock.withLock {
            drainMs = nil
            drainTarget = (end, since)
            noteDrain(at: CACurrentMediaTime())
        }
    }

    /// Called with `lock` held.
    private func noteDrain(at now: CFTimeInterval) {
        guard let target = drainTarget, processed >= target.end else { return }
        drainMs = max(0, (now - target.since) * 1000)
        drainTarget = nil
    }

    /// Raw session bytes (before the row shift) Ghostty finished processing.
    public func outputProcessed(_ bytes: Int) {
        lock.withLock {
            processed += bytes
            noteDrain(at: CACurrentMediaTime())
            while let first = echoes.first, first.end <= processed {
                echoes.removeFirst()
                awaitingPresent += first.keys
            }
        }
    }

    /// A frame was presented on screen.
    public func presented() {
        let now = CACurrentMediaTime()
        lock.withLock {
            presents += 1
            if let lastPresent { frameIntervals.append((now - lastPresent) * 1000) }
            lastPresent = now
            for key in awaitingPresent { latencies.append((now - key) * 1000) }
            awaitingPresent.removeAll()
        }
    }

    public func keystroke(at time: CFTimeInterval) {
        lock.withLock { keystrokes.append(time) }
    }

    /// The fake daemon put `count` echoed keystrokes in the stream, ending at session byte `end`.
    public func echo(count: Int, endingAt end: Int) {
        lock.withLock {
            let keys = Array(keystrokes.prefix(count))
            keystrokes.removeFirst(min(count, keystrokes.count))
            echoes.append((end, keys))
        }
    }

    public struct Snapshot: Sendable {
        public var processed: Int
        public var presents: Int
        public var echoLatencies: [Double]
        public var pendingEchoes: Int
        /// Milliseconds between consecutive presented frames since the last `take()`.
        public var frameIntervals: [Double]
        /// The timed drain's milliseconds (``timeDrain(until:since:)``); nil while it runs or when none was asked for.
        public var drainMs: Double?
    }

    /// Counters so far; echo latencies and frame intervals are handed over (and cleared).
    public func take() -> Snapshot {
        lock.withLock {
            defer { latencies.removeAll(); frameIntervals.removeAll() }
            return Snapshot(processed: processed, presents: presents, echoLatencies: latencies,
                            pendingEchoes: keystrokes.count + echoes.reduce(0) { $0 + $1.keys.count } + awaitingPresent.count,
                            frameIntervals: frameIntervals, drainMs: drainMs)
        }
    }
}
#endif
