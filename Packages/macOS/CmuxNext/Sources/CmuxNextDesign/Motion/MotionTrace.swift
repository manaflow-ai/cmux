public import QuartzCore

/// Measured animation spans for `debug.motion` (plans/cmux-next/motion.md).
/// Off by default: every hook is one Bool check. While on, a span opens at
/// the first start of a named animation and closes when it settles, so a
/// retargeted animation counts once, from first frame to rest.
public enum MotionTrace {
    public struct Span: Sendable, Equatable {
        public var name: String
        public var start: CFTimeInterval
        public var milliseconds: Double
    }

    public private(set) static var isEnabled = false
    private static var open: [String: CFTimeInterval] = [:]
    public private(set) static var spans: [Span] = []
    static let capacity = 1024

    public static func start() {
        isEnabled = true
        open.removeAll()
        spans.removeAll()
    }

    public static func stop() {
        isEnabled = false
        open.removeAll()
    }

    public static func begin(_ name: String) {
        guard isEnabled, open[name] == nil else { return }
        open[name] = CACurrentMediaTime()
    }

    public static func end(_ name: String) {
        guard isEnabled, let start = open.removeValue(forKey: name), spans.count < capacity else { return }
        spans.append(Span(name: name, start: start, milliseconds: (CACurrentMediaTime() - start) * 1000))
    }
}
