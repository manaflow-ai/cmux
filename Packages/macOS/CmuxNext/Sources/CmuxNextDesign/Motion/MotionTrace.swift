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
    public private(set) static var samples: [Sample] = []
    /// When recording started (sample times are reported from here).
    public private(set) static var startedAt: CFTimeInterval = 0
    static let capacity = 1024
    static let sampleCapacity = 8192

    public static func start() {
        isEnabled = true
        open.removeAll()
        spans.removeAll()
        samples.removeAll()
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

    public static func end(_ name: String, id: ObjectIdentifier? = nil) {
        guard isEnabled, let start = open.removeValue(forKey: key(name, id)), spans.count < capacity else { return }
        spans.append(Span(name: name, start: start, milliseconds: (CACurrentMediaTime() - start) * 1000))
    }

    /// One value of `name` at this frame (only while recording).
    public static func sample(_ name: String, _ value: Double) {
        guard isEnabled, samples.count < sampleCapacity else { return }
        samples.append(Sample(name: name, time: CACurrentMediaTime(), value: value))
    }

    private static func key(_ name: String, _ id: ObjectIdentifier?) -> String {
        id.map { "\(name)#\($0.hashValue)" } ?? name
    }
}
