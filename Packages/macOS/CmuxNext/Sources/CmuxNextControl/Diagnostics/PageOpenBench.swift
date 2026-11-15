#if DEBUG || CMUX_BENCH_HOOKS
import Foundation
public import CmuxNextSettings

/// The app's pool of prewarmed page hosts (Settings, History, Cloud) as `debug.page_open_bench` drives it.
@MainActor
public protocol PageSpareBenchPool: AnyObject {
    /// The parked spare loaded, so a claim shows it at once.
    var isSpareReady: Bool { get }
    /// The spare plus the claimed hosts.
    var hostCount: Int { get }
    /// Claims that took the spare so far.
    var spareClaims: Int { get }
    /// How long the spare stays with no sign of intent or claim; nil keeps it.
    var idleLimit: Duration? { get set }
    /// A sign of intent: builds the spare now.
    func noteIntent()
    /// Frees the spare as the idle limit does.
    func releaseIdle()
    /// Page `id` shows painted in a window, not as the parked spare.
    func isPageShown(_ id: String) -> Bool
}

/// `debug.page_open_bench`: one open of Settings, History or Cloud as its menu item runs it, timed to the first
/// display frame that shows the page painted (scripts/cmux-next/page-spare-bench.py, CMUX-571).
///
/// Params: `page` (`settings`, `history`, `cloud`); `mode`: `as_is` (the pool as it is: a fresh launch's first open),
/// or `intent` (a sign of intent, then the open `lead_ms` later, default 200). `idle_limit_s` (seconds, or null for
/// never) sets the pool's idle limit and opens nothing; `release_idle: true` frees the spare and opens nothing.
///
/// Reports, in ms from the open: `drawn_ms` (the first display frame with the page painted on screen), and
/// `spare_ready_before`, `spare` (the open took the spare), `host_count_before`, and for `intent`
/// `intent_ready_ms` (the sign of intent to the spare loaded; null when it had not loaded by the open).
@MainActor
public final class PageOpenBench {
    public static let pages: [String: (id: String, action: String)] = [
        "settings": ("cmux.settings", "openSettings"),
        "history": ("cmux.history", "history.show"),
        "cloud": ("cmux.cloud", "palette.openCloudPane"),
    ]
    private let pool: PageSpareBenchPool
    /// Runs an action by id; false when it did not run.
    private let perform: (String) -> Bool
    private let frames = BenchFrames()

    public init(pool: PageSpareBenchPool, perform: @escaping (String) -> Bool) {
        self.pool = pool
        self.perform = perform
    }

    public func run(_ params: [String: JSONValue]) async -> JSONValue {
        if params["release_idle"]?.boolValue == true {
            pool.releaseIdle()
            return .object(["released": true, "host_count": .number(Double(pool.hostCount))])
        }
        if let limit = params["idle_limit_s"] {
            pool.idleLimit = limit.doubleValue.map { Duration.seconds($0) }
            return .object(["idle_limit_s": limit])
        }
        let name = params["page"]?.stringValue ?? "settings", mode = params["mode"]?.stringValue ?? "as_is"
        let lead = params["lead_ms"]?.doubleValue ?? 200
        guard let page = Self.pages[name] else { return .object(["error": .string("page: one of \(Self.pages.keys.sorted())")]) }
        frames.start()
        defer { _ = frames.stop() }
        var intentReady: Double?
        if mode == "intent" {
            let intent = ContinuousClock.now
            pool.noteIntent()
            intentReady = await frames.settled(until: { [pool] in pool.isSpareReady }, start: intent, window: 0, deadline: lead)
            _ = await frames.settled(until: { false }, start: intent, window: 0, deadline: lead)
        } else {
            // Quiet frames first, so the open starts from an idle main thread.
            _ = await frames.settled(until: { true }, start: .now, window: 120, deadline: 1_000)
        }
        let readyBefore = pool.isSpareReady, hostsBefore = pool.hostCount, claimsBefore = pool.spareClaims
        let start = ContinuousClock.now
        guard perform(page.action) else { return .object(["page": .string(name), "mode": .string(mode), "error": "the open action did not run"]) }
        let drawn = await frames.settled(until: { [pool] in pool.isPageShown(page.id) }, start: start, window: 100, deadline: 5_000)
        return .object([
            "page": .string(name), "mode": .string(mode),
            "spare_ready_before": .bool(readyBefore), "host_count_before": .number(Double(hostsBefore)),
            "spare": .bool(pool.spareClaims > claimsBefore),
            "lead_ms": mode == "intent" ? .number(lead) : .null,
            "intent_ready_ms": intentReady.map { .number($0) } ?? .null,
            "drawn_ms": drawn.map { .number($0) } ?? .null,
        ])
    }
}
#endif
