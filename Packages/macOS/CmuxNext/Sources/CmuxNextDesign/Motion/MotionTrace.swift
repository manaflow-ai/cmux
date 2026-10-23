public import QuartzCore

/// Measured animation spans for `debug.motion` (plans/cmux-next/motion.md).
/// Off by default: every hook is one Bool check. While on, a span opens at
/// the first start of a named animation and closes when it settles, so a
/// retargeted animation counts once, from first frame to rest. Two
/// animators with one name (two tab strips) keep separate spans (`id`).
/// `sample` records one value per frame (the clock's dt, the travel a strip
/// or layout has left), so a bench reads the spring's path, not only its
/// length.
public struct MotionTrace {
    public init() {}
    public struct Span: Sendable, Equatable {
        public var name: String
        public var start: CFTimeInterval
        public var milliseconds: Double
    }

    public struct Sample: Sendable, Equatable {
        public var name: String
        public var time: CFTimeInterval
        public var value: Double
    }

    public private(set) static var isEnabled = false
    private static var open: [String: CFTimeInterval] = [:]
    public private(set) static var spans: [Span] = []
    /// Main-thread work per frame of each animation `measure` times, in ms; `ca.commit` is each
    /// Core Animation commit of the main run loop while a ``MotionCommitProbe`` records (the
    /// `debug.motion` handler's), which includes Chromium's pre-commit wait for a page's frame at a
    /// new size.
    public private(set) static var work: [String: [Double]] = [:]
    public private(set) static var samples: [Sample] = []
    /// What an animator decided at a time (`note`), for a bench that must tell why something moved.
    public private(set) static var notes: [(time: CFTimeInterval, text: String)] = []
    /// When recording started (sample times are reported from here).
    public private(set) static var startedAt: CFTimeInterval = 0
    static let capacity = 1024
    static let sampleCapacity = 8192
    public static func start() {
        isEnabled = true
        open.removeAll()
        spans.removeAll()
        work.removeAll()
        samples.removeAll()
        notes.removeAll()
        startedAt = CACurrentMediaTime()
    }

    public static func stop() {
        isEnabled = false
        open.removeAll()
    }

    public static func begin(_ name: String, id: ObjectIdentifier? = nil) {
        let key = key(name, id)
        guard isEnabled, open[key] == nil else { return }
        open[key] = CACurrentMediaTime()
    }

    /// Runs one frame of the animation `name`; while on, records how long it took.
    public static func measure<T>(_ name: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = CACurrentMediaTime()
        let result = body()
        record(name, milliseconds: (CACurrentMediaTime() - start) * 1000)
        return result
    }

    /// One frame's main-thread work of `name` timed elsewhere (only while recording).
    static func record(_ name: String, milliseconds: Double) {
        guard isEnabled, work[name, default: []].count < capacity * 16 else { return }
        work[name, default: []].append(milliseconds)
    }

    public static func end(_ name: String, id: ObjectIdentifier? = nil) {
        guard isEnabled, let start = open.removeValue(forKey: key(name, id)), spans.count < capacity else { return }
        spans.append(Span(name: name, start: start, milliseconds: (CACurrentMediaTime() - start) * 1000))
    }

    /// One value of `name` at this frame (only while recording).
    public static func sample(_ name: String, _ value: Double) {
        guard isEnabled, samples.count < sampleCapacity else { return }
        samples.append(Sample(name: name, time: CACurrentMediaTime(), value: value))
    }

    /// One decision of an animator (only while recording; the text is built only then).
    public static func note(_ text: @autoclosure () -> String) {
        guard isEnabled, notes.count < capacity else { return }
        notes.append((CACurrentMediaTime(), text()))
    }

    private static func key(_ name: String, _ id: ObjectIdentifier?) -> String {
        id.map { "\(name)#\($0.hashValue)" } ?? name
    }
}
