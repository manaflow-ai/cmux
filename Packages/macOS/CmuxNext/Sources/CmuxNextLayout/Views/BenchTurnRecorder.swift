public import AppKit

/// CMD-N FIRST FRAME instrument (never merged): the main run loop's turns while a bench runs.
/// `turn` is a wake until the first before-waiting observer (events, timers, sources, main-queue
/// work); `turn.commit` is the before-waiting observers (AppKit's layout and display, the CA commit).
public nonisolated final class BenchTurnRecorder {
    public struct Span {
        public let name: String
        public let start: Double
        public let milliseconds: Double
    }

    private var spans: [Span] = []
    private var origin: ContinuousClock.Instant?
    private var turnStart: ContinuousClock.Instant?
    private var commitStart: ContinuousClock.Instant?
    private var observers: [CFRunLoopObserver] = []

    /// The main thread's recorder, made and installed once.
    public static func main() -> BenchTurnRecorder {
        if let recorder = Thread.main.threadDictionary["cmux.benchTurns"] as? BenchTurnRecorder { return recorder }
        let recorder = BenchTurnRecorder()
        recorder.install()
        Thread.main.threadDictionary["cmux.benchTurns"] = recorder
        return recorder
    }

    public func start(_ origin: ContinuousClock.Instant) {
        self.origin = origin
        spans.removeAll(keepingCapacity: true)
        (turnStart, commitStart) = (nil, nil)
    }

    public func stop() -> [Span] {
        origin = nil
        return spans
    }

    private func install() {
        let first = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.min) { [weak self] _, activity in
            self?.first(activity)
        }
        let last = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            self?.last()
        }
        for observer in [first, last].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    private func first(_ activity: CFRunLoopActivity) {
        guard let origin else { return }
        let now = ContinuousClock.now
        if activity == .afterWaiting {
            turnStart = now
            return
        }
        if let started = turnStart { record("turn", from: started, to: now, origin: origin) }
        turnStart = nil
        commitStart = now
    }

    private func last() {
        guard let origin, let started = commitStart else { return }
        commitStart = nil
        record("turn.commit", from: started, to: .now, origin: origin)
    }

    private func record(_ name: String, from start: ContinuousClock.Instant, to end: ContinuousClock.Instant, origin: ContinuousClock.Instant) {
        let took = Self.ms(end - start)
        guard took > 0.05, spans.count < 512 else { return }
        spans.append(Span(name: name, start: Self.ms(start - origin), milliseconds: took))
    }

    private static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }

    /// CMD-N FIRST FRAME instrument: a key-window change's label: the window's class and its callers (no AppKit frames).
    public static func keyLabel(_ label: String, _ window: NSWindow?) -> String {
        let frames = Thread.callStackSymbols.dropFirst(2).compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, !["AppKit", "CoreFoundation", "Foundation", "libdispatch.dylib"].contains(String(parts[1])) else { return nil }
            return parts[1] + ":" + String(parts[3...].joined(separator: " ").prefix(90))
        }
        return label + " " + (window.map { String(describing: type(of: $0)) } ?? "nil") + " | " + frames.prefix(14).joined(separator: " < ")
    }
}
