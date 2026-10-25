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

    public init() {}

    /// Raw session bytes (before the row shift) Ghostty finished processing.
    public func outputProcessed(_ bytes: Int) {
        lock.withLock {
            processed += bytes
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
    }

    /// Counters so far; echo latencies are handed over (and cleared).
    public func take() -> Snapshot {
        lock.withLock {
            defer { latencies.removeAll() }
            return Snapshot(processed: processed, presents: presents, echoLatencies: latencies,
                            pendingEchoes: keystrokes.count + echoes.reduce(0) { $0 + $1.keys.count } + awaitingPresent.count)
        }
    }
}
#endif
