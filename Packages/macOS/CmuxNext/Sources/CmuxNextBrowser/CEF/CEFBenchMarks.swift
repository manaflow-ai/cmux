#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation

/// DEBUG builds: the points of a Chromium page's creation that the app's new Chromium tab bench
/// (`debug.new_tab {action: "bench_browser"}`) lines up with the key: the main-thread time of
/// building a Chromium window (`create_window`) or joining one (`tab_add`), the window's arrival,
/// a spare window taken, and the page's first contentful paint per tab id.
///
/// Disarmed (no ``sink``) a mark site costs one optional read.
/// The runtime owns the one recorder (`CEFRuntime.benchMarks`); the app reaches it through
/// `CEFEngine.benchMarks`.
@MainActor
public final class CEFBenchMarks {

    /// Receives each mark: its name, and its main-thread milliseconds (0 for a point in time).
    public private(set) var sink: ((_ name: String, _ milliseconds: Double) -> Void)?

    /// Tab ids whose page had its first contentful paint, with the uptime it came at.
    public private(set) var firstPaints: [String: TimeInterval] = [:]

    /// Arms the recorder with `sink` (nil disarms it); forgets earlier first paints.
    public func arm(_ sink: ((_ name: String, _ milliseconds: Double) -> Void)?) {
        self.sink = sink
        firstPaints.removeAll()
    }

    /// Records the point `name`.
    func point(_ name: String) { sink?(name, 0) }

    /// Runs `body`, recording its main-thread time under `name`.
    func span<T>(_ name: String, _ body: () -> T) -> T {
        guard let sink else { return body() }
        let start = ProcessInfo.processInfo.systemUptime
        let value = body()
        sink(name, (ProcessInfo.processInfo.systemUptime - start) * 1_000)
        return value
    }

    /// Tab `id`'s page painted content for the first time.
    func firstPaint(_ id: String) {
        guard sink != nil, firstPaints[id] == nil else { return }
        firstPaints[id] = ProcessInfo.processInfo.systemUptime
        point("cef.first_paint")
    }
}
#endif
