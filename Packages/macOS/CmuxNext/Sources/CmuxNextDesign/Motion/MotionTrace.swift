public import QuartzCore

/// Measured animation spans for `debug.motion` (plans/cmux-next/motion.md).
/// Off by default: every hook is one Bool check. While on, a span opens at
/// the first start of a named animation and closes when it settles, so a
/// retargeted animation counts once, from first frame to rest.
public struct MotionTrace {
    public init() {}
    public struct Span: Sendable, Equatable {
        public var name: String
        public var start: CFTimeInterval
        public var milliseconds: Double
    }

    public private(set) static var isEnabled = false
    private static var open: [String: CFTimeInterval] = [:]
    public private(set) static var spans: [Span] = []
    /// Main-thread work per frame of each animation `measure` times, in ms.
    public private(set) static var work: [String: [Double]] = [:]
    static let capacity = 1024

    public static func start() {
        isEnabled = true
        open.removeAll()
        spans.removeAll()
        work.removeAll()
    }

    public static func stop() {
        isEnabled = false
        open.removeAll()
    }

    public static func begin(_ name: String) {
        guard isEnabled, open[name] == nil else { return }
        open[name] = CACurrentMediaTime()
    }

    /// Runs one frame of the animation `name`; while on, records how long it took.
    public static func measure<T>(_ name: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = CACurrentMediaTime()
        let result = body()
        if work[name, default: []].count < capacity * 16 { work[name, default: []].append((CACurrentMediaTime() - start) * 1000) }
        return result
    }

    public static func end(_ name: String) {
        guard isEnabled, let start = open.removeValue(forKey: name), spans.count < capacity else { return }
        spans.append(Span(name: name, start: start, milliseconds: (CACurrentMediaTime() - start) * 1000))
    }
}
