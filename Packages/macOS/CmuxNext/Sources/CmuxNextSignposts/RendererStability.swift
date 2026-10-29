import CmuxNextMetrics
public import CmuxNextTrace

/// WebKit content-process ends and Chromium "Page unresponsive" spans as stability events.
///
/// Each event writes three things, none of which names the page (no URL, title or host):
/// - a trace ring record in the `crash` category: one ``SignpostName/crashWebContentEnd`` instant per content end,
///   one ``SignpostName/crashRendererUnresponsive`` async slice (AB/AE) per hang, from the "Page unresponsive" state's
///   start to its end. `arg0` is the ``Surface`` code.
/// - stability counts in the metrics file: one `stability.renderer.<event>.<engine>` sample per page, its value the
///   surface (``HistogramID/RendererSurface``): each page a content process served when it ended, each page that
///   started a hang. `stability.child_exit.webkit` (``HistogramID/ChildExit/signal``) counts each ended WebContent
///   process once, however many pages it served (WebKit tells each of them). One `renderer.unresponsive_ms` sample per
///   hang that ended, its length in ms.
/// - a rate-limited ``Report`` to the sink (crash reporting in the app): the first event of a kind, engine and surface
///   goes at once, the next ones of that key in the following hour only count, and the next event after the hour carries
///   the count since the last report. 3 ends in a minute are 3 counts and 1 report.
///
/// Chrome counts renderer process ends per process type the same way (components/metrics/stability_metrics_helper.cc,
/// `LogRendererCrash`), and follows a hang from `WebContentsDelegate::RendererUnresponsive` to `RendererResponsive`
/// (content/public/browser/web_contents_delegate.h); task 083 limits Chromium helper-exit reports to 1 per type per hour.
/// A process end counts once per process as `RenderProcessHostObserver::RenderProcessExited` runs once per host
/// (content/public/browser/render_process_host_observer.h): a page names the WebContent process it last committed in.
///
/// All calls come from the engines' delegate callbacks on the main thread; a call does no I/O and the sink only hands
/// the report off.
///
/// ```swift
/// let stability = RendererStability(sink: { report in sentry.send(report) })
/// stability.webKitContentCommitted(in: pid)
/// stability.webKitContentEnded(on: .browserTab, process: pid)
/// stability.unresponsiveShown(ObjectIdentifier(tab), surface: .browserTab)
/// stability.unresponsiveEnded(ObjectIdentifier(tab), .responsive)
/// ```
@MainActor
public final class RendererStability {
    /// The engine whose process the event is about.
    public enum Engine: String, Sendable, CaseIterable {
        /// A WebKit WebContent process.
        case webKit = "webkit"
        /// A Chromium renderer.
        case chromium

        var metric: HistogramID.RendererEngine {
            switch self {
            case .webKit: .webkit
            case .chromium: .chromium
            }
        }
    }

    /// The kind of view that showed the page.
    public enum Surface: UInt64, Sendable, CaseIterable {
        /// A browser tab (`WebKitTab`, `CEFTab`).
        case browserTab = 1
        /// A cmux page (`PageWebView`: Home, Settings, the agent chat), or a cmux page shown in a Chromium tab.
        case page = 2
        /// The agent pages' WebKit warm-up page (`AgentPageWarmup`).
        case warmup = 3

        /// The surface's value in the `stability.renderer` counts.
        var metric: HistogramID.RendererSurface {
            switch self {
            case .browserTab: .browserTab
            case .page: .page
            case .warmup: .warmup
            }
        }

        /// The report's name of the surface.
        public var name: String {
            switch self {
            case .browserTab: "browser_tab"
            case .page: "page"
            case .warmup: "warmup"
            }
        }
    }

    /// What happened.
    public enum Kind: String, Sendable, CaseIterable {
        /// The content process ended under the page (`webViewWebContentProcessDidTerminate`).
        case contentEnded = "content_ended"
        /// The page stopped handling input ("Page unresponsive"), reported when that state ended.
        case unresponsive
    }

    /// How a "Page unresponsive" span ended.
    public enum UnresponsiveEnd: String, Sendable, CaseIterable {
        /// The renderer handled input again, or the person chose Wait.
        case responsive
        /// The renderer ended (a crash, or the person chose Exit page).
        case processEnded = "process_ended"
        /// A new navigation replaced the hung document.
        case navigated
        /// The tab closed while its page hung.
        case closed
    }

    /// One report: closed-set names and numbers only.
    public struct Report: Sendable, Equatable {
        public let kind: Kind
        public let engine: Engine
        public let surface: Surface
        /// Events of this kind, engine and surface since the last report, this one included.
        public let count: Int
        /// An unresponsive span's length in ms; nil for a content end.
        public let unresponsiveMilliseconds: Int64?
        /// How an unresponsive span ended; nil for a content end.
        public let ending: UnresponsiveEnd?
    }

    /// Takes each report on the main thread: hand it off and return (the app's posts it to the crash-reporting lane).
    public typealias Sink = @MainActor (Report) -> Void

    private struct Key: Hashable {
        let kind: Kind
        let engine: Engine
        let surface: Surface
    }

    /// One key's limiter state: when its last report went, and the events since then.
    private struct Limit {
        var lastReportNanos: UInt64?
        var pending = 0
    }

    private struct Span {
        let interval: SignpostInterval
        let engine: Engine
        let surface: Surface
    }

    private let signposter: Signposter
    private let metrics: Metrics
    private let sink: Sink?
    private let reportIntervalNanos: UInt64
    private var limits: [Key: Limit] = [:]
    /// The open "Page unresponsive" spans, by page.
    private var spans: [ObjectIdentifier: Span] = [:]
    /// The WebContent processes whose end was counted, until a page commits in that pid again (a pid can be reused).
    private var endedProcesses: Set<Int32> = []

    /// - Parameters:
    ///   - trace: The runtime whose ring and metrics file take the records (the process's by default; tests pass theirs).
    ///   - clock: The clock of the spans and the limiter (tests pass a counter).
    ///   - reportInterval: How long after a report the next events of its key only count.
    ///   - sink: Where reports go; nil records the ring and the counts only.
    public init(trace: TraceRuntime = .shared, clock: TraceClock = TraceClock(), reportInterval: Duration = .seconds(3_600),
                sink: Sink? = nil) {
        signposter = Signposter(category: .crash, mirror: .shared, trace: trace, clock: clock)
        metrics = Metrics(runtime: trace)
        let (seconds, attoseconds) = reportInterval.components
        reportIntervalNanos = UInt64(clamping: max(0, seconds) &* 1_000_000_000 &+ attoseconds / 1_000_000_000)
        self.sink = sink
    }

    /// Whether `page` shows "Page unresponsive" now (an open span).
    public func isUnresponsive(_ page: ObjectIdentifier) -> Bool { spans[page] != nil }

    /// A WebKit page committed a document in content process `process`: that process lives, so a later end under its
    /// pid is a new process's.
    public func webKitContentCommitted(in process: Int32) {
        endedProcesses.remove(process)
    }

    /// A WebKit content process ended under a page of `surface`. WebKit's public delegate call gives no reason: a
    /// content process that ends under a live page crashed or was killed, so it counts as ``HistogramID/ChildExit/signal``.
    ///
    /// - Parameters:
    ///   - surface: The kind of view that showed the page.
    ///   - process: The pid the page last committed in (``webKitContentCommitted(in:)``); the other pages of that
    ///     process add no process end. Nil (no commit yet) counts the end as its own process.
    public func webKitContentEnded(on surface: Surface, process: Int32?) {
        signposter.event(.crashWebContentEnd, "surface=\(surface.name)", arg0: surface.rawValue)
        metrics.record(.stabilityRenderer(.contentEnd, .webkit), surface.metric.rawValue)
        let newProcess = process.map { endedProcesses.insert($0).inserted } ?? true
        if newProcess {
            metrics.record(.stabilityChildExit(.webkit), HistogramID.ChildExit.signal.rawValue)
        }
        report(Key(kind: .contentEnded, engine: .webKit, surface: surface), milliseconds: nil, ending: nil)
    }

    /// `page` started showing "Page unresponsive": its span opens, and the hang counts at its start, so a hang the app
    /// never sees end still counts. A second call before its end changes nothing.
    public func unresponsiveShown(_ page: ObjectIdentifier, engine: Engine = .chromium, surface: Surface) {
        guard spans[page] == nil else { return }
        let interval = signposter.begin(.crashRendererUnresponsive, "surface=\(surface.name)", arg0: surface.rawValue)
        spans[page] = Span(interval: interval, engine: engine, surface: surface)
        metrics.record(.stabilityRenderer(.unresponsive, engine.metric), surface.metric.rawValue)
    }

    /// `page` stopped showing "Page unresponsive" for `ending`: its span ends, and its length is one
    /// `renderer.unresponsive_ms` sample. A page with no open span records nothing.
    public func unresponsiveEnded(_ page: ObjectIdentifier, _ ending: UnresponsiveEnd) {
        guard let span = spans.removeValue(forKey: page) else { return }
        let now = signposter.nowNanos()
        let begin = span.interval.beginUptimeNanos
        let milliseconds = Int64(clamping: (now > begin ? now - begin : 0) / 1_000_000)
        signposter.end(.crashRendererUnresponsive, span.interval)
        metrics.record(.rendererUnresponsive, milliseconds)
        report(Key(kind: .unresponsive, engine: span.engine, surface: span.surface), milliseconds: milliseconds, ending: ending)
    }

    private func report(_ key: Key, milliseconds: Int64?, ending: UnresponsiveEnd?) {
        guard let sink else { return }
        var limit = limits[key] ?? Limit()
        limit.pending += 1
        let now = signposter.nowNanos()
        if let last = limit.lastReportNanos, now < last &+ reportIntervalNanos {
            limits[key] = limit
            return
        }
        limits[key] = Limit(lastReportNanos: now, pending: 0)
        sink(Report(kind: key.kind, engine: key.engine, surface: key.surface, count: limit.pending,
                    unresponsiveMilliseconds: milliseconds, ending: ending))
    }
}
