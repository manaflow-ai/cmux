#if DEBUG || CMUX_BENCH_HOOKS
import Foundation
public import CmuxNextSettings

/// A WebKit overlay page made ahead of its opens and freed when unused (the icon picker, the group editor), as
/// `debug.overlay_open_bench` drives it.
@MainActor
public protocol OverlayBenchPage: AnyObject {
    /// The panel and page exist, so an open reuses them.
    var isWarm: Bool { get }
    /// The page also loaded, so an open draws at once.
    var isPageReady: Bool { get }
    /// An open is in progress (shown or waiting for its page).
    var isOpen: Bool { get }
    /// How long the made page stays with no open before it is freed; nil keeps it.
    var idleLimit: Duration? { get set }
    /// The open card is on screen.
    var isCardShown: Bool { get }
    /// The open card is on screen with its page drawn for the open that started at `start`.
    func drawn(since start: ContinuousClock.Instant) -> Bool
    /// Makes the page, as a sign of intent does.
    func prepare()
    /// Frees the page while nothing is open.
    func release()
    /// Closes the open card as a click outside does.
    func cancelOpen()
}

/// `debug.overlay_open_bench`: one open of an overlay page as its menu item runs it, timed to the first display
/// frame that shows it drawn, then closed (scripts/cmux-next/overlay-open-bench.py).
///
/// Params: `kind` (a key of `pages`); `mode`: `warm` (the page made and loaded first: the open reuses it), `cold` (the
/// page freed first: the open makes it), `intent` (freed, then made as a menu or palette open makes it, and the open
/// `lead_ms` later, default 300), or `as_is`. `release: true` frees every page and opens nothing; `idle_limit_s`
/// (seconds, or null for never) sets every page's idle limit and opens nothing.
///
/// Reports, in ms from the open: `drawn_ms` (the first display frame with the card on screen and its page drawn),
/// `shown_ms` (the card on screen at all), `created_page`, `page_ready_before`, and for `intent` `intent_ready_ms`
/// (the sign of intent to the page loaded; null when it had not loaded by the open).
@MainActor
public final class OverlayOpenBench {
    private let pages: [String: OverlayBenchPage]
    /// Runs the open action of a kind (Set Icon, Rename Group); false when it did not run.
    private let open: (String) -> Bool
    private let frames = BenchFrames()

    public init(pages: [String: OverlayBenchPage], open: @escaping (String) -> Bool) {
        self.pages = pages
        self.open = open
    }

    public func run(_ params: [String: JSONValue]) async -> JSONValue {
        if params["release"]?.boolValue == true {
            pages.values.forEach { $0.release() }
            return .object(["released": true, "warm": .array(pages.values.map { .bool($0.isWarm) })])
        }
        if let limit = params["idle_limit_s"] {
            let duration = limit.doubleValue.map { Duration.seconds($0) }
            pages.values.forEach { $0.idleLimit = duration }
            return .object(["idle_limit_s": limit])
        }
        let kind = params["kind"]?.stringValue ?? "icon_picker", mode = params["mode"]?.stringValue ?? "as_is"
        let lead = params["lead_ms"]?.doubleValue ?? 300
        guard let page = pages[kind] else { return .object(["error": .string("kind: one of \(pages.keys.sorted())")]) }
        frames.start()
        defer { _ = frames.stop() }
        switch mode {
        case "warm":
            page.prepare()
            _ = await frames.settled(until: { page.isPageReady }, start: .now, window: 200, deadline: 10_000)
        case "cold", "intent":
            page.release()
            // The freed page's process winds down before the open, as minutes of idle would leave it.
            _ = await frames.settled(until: { !page.isWarm }, start: .now, window: 1_000, deadline: 5_000)
        default:
            break
        }
        var intentReady: Double?
        if mode == "intent" {
            let intent = ContinuousClock.now
            page.prepare()
            intentReady = await frames.settled(until: { page.isPageReady }, start: intent, window: 0, deadline: lead)
            _ = await frames.settled(until: { false }, start: intent, window: 0, deadline: lead)
        } else {
            // Quiet frames first, so the open starts from an idle main thread.
            _ = await frames.settled(until: { true }, start: .now, window: 120, deadline: 1_000)
        }
        let createdPage = !page.isWarm, readyBefore = page.isPageReady
        let start = ContinuousClock.now
        guard open(kind) else { return .object(["kind": .string(kind), "mode": .string(mode), "error": "the open action did not run"]) }
        var shown: Double?
        let drawn = await frames.settled(until: {
            guard page.isCardShown else { return false }
            if shown == nil { shown = Self.ms(.now - start) }
            return page.drawn(since: start)
        }, start: start, window: 100, deadline: 5_000)
        page.cancelOpen()
        _ = await frames.settled(until: { !page.isOpen }, start: .now, window: 300, deadline: 3_000)
        return .object([
            "kind": .string(kind), "mode": .string(mode),
            "created_page": .bool(createdPage), "page_ready_before": .bool(readyBefore),
            "lead_ms": mode == "intent" ? .number(lead) : .null,
            "intent_ready_ms": intentReady.map { .number($0) } ?? .null,
            "drawn_ms": drawn.map { .number($0) } ?? .null,
            "shown_ms": shown.map { .number($0) } ?? .null,
        ])
    }

    private static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
#endif
