#if os(iOS)
import OSLog
import QuartzCore

/// Scratch (never lands): F3 timing marks for the grid open, read by listperf
/// from the frames log (`list-stress` lines).
@MainActor
public enum F3Trace {
    static let log = Logger(subsystem: "dev.cmux.mobile", category: "frames")
    private static var link: CADisplayLink?
    private static var last: CFTimeInterval = 0
    private static var marks: [String: Int] = [:]

    public static func time<T>(_ name: String, _ body: () -> T) -> T {
        let start = CACurrentMediaTime()
        let value = body()
        let ms = (CACurrentMediaTime() - start) * 1000
        log.notice("FRAMELOG list-stress f3 \(name, privacy: .public) t=\(String(format: "%.3f", start), privacy: .public) ms=\(String(format: "%.1f", ms), privacy: .public)")
        return value
    }

    /// A point event (a body evaluation, a phase change); body marks are counted, logged once per 10.
    public static func mark(_ name: String) {
        marks[name, default: 0] += 1
        let n = marks[name]!
        guard n <= 3 || n % 10 == 0 else { return }
        log.notice("FRAMELOG list-stress f3 mark \(name, privacy: .public) n=\(n) t=\(String(format: "%.3f", CACurrentMediaTime()), privacy: .public)")
    }

    /// Logs every display gap over 50 ms with when it ended.
    public static func watchFrames() {
        guard link == nil else { return }
        let link = CADisplayLink(target: Proxy(), selector: #selector(Proxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate static func tick(_ now: CFTimeInterval) {
        if last > 0, now - last > 0.05 {
            log.notice("FRAMELOG list-stress f3 longframe end=\(String(format: "%.3f", now), privacy: .public) gap=\(String(format: "%.1f", (now - last) * 1000), privacy: .public)")
        }
        last = now
    }

    private final class Proxy: NSObject {
        @objc func tick(_ link: CADisplayLink) {
            let now = link.timestamp
            MainActor.assumeIsolated { F3Trace.tick(now) }
        }
    }
}
#endif
