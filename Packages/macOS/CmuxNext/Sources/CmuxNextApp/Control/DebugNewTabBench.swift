#if DEBUG
import AppKit
import CmuxNextSettings
import CmuxNextWakeups

/// `debug.new_tab` benches (R81): Cmd-W on a new tab page and `!` in its
/// field, each driven through the real key path (`debug.key`), with the
/// key's synchronous main-thread time, the main-thread spans recorded by
/// `BenchSpans`, and display-link frame intervals over the bench window
/// (a missed frame is an interval longer than 1.5 refresh periods).
@MainActor
enum DebugNewTabBench {
    private static let frames = BenchFrames()
    static let window: Duration = .milliseconds(400)

    /// `bench_close`: the focused pane of window `window` shows a new tab page; Cmd-W closes it.
    static func close(_ params: [String: JSONValue], _ controller: WindowController, _ services: AppServices) async -> JSONValue {
        guard let pane = controller.content?.focusedPane, let key = pane.currentTabKey, services.agentTabs.isNewTabPage(key) else {
            return .object(["error": .string("the focused pane shows no new tab page")])
        }
        return await run(services) {
            _ = DebugKey.send(["key": .string("w"), "modifiers": .array([.string("command")]), "window": .string(controller.state.id)],
                              services: services)
        } until: { _ in true }
    }

    /// `bench_open`: Cmd-T in the focused pane of window `window`; measured until that pane shows
    /// the new tab page and its strip shows the tab. `opening` says whether a spare was adopted and
    /// whether it had to change size (a relayout at adoption), `frames.first_tick_ms` when the
    /// first display frame after the key came.
    static func open(_ params: [String: JSONValue], _ controller: WindowController, _ services: AppServices) async -> JSONValue {
        guard let pane = controller.content?.focusedPane else { return .object(["error": .string("no focused pane")]) }
        let before = services.newTabSpares.openings.count
        var result = await run(services) {
            _ = DebugKey.send(["key": .string("t"), "modifiers": .array([.string("command")]), "window": .string(controller.state.id)],
                              services: services)
        } until: { _ in
            guard services.newTabSpares.openings.count > before, let key = pane.currentTabKey else { return false }
            return services.agentTabs.isNewTabPage(key) && pane.view.stripView.presentedTabIDs.contains { $0.rawValue == key }
        }
        if case .object(var fields) = result {
            let opening = services.newTabSpares.openings.count > before ? services.newTabSpares.openings.last : nil
            fields["opening"] = opening.map {
                .object(["spare": .bool($0.spare), "refit": .bool($0.refit), "ms": .number($0.milliseconds)])
            } ?? .null
            result = .object(fields)
        }
        return result
    }

    /// `bench_bang`: `!` typed into the focused new tab page; measured until a terminal shows.
    static func bang(_ params: [String: JSONValue], _ controller: WindowController, _ services: AppServices) async -> JSONValue {
        guard let pane = controller.content?.focusedPane, let key = pane.currentTabKey, services.agentTabs.isNewTabPage(key) else {
            return .object(["error": .string("the focused pane shows no new tab page")])
        }
        return await run(services) {
            _ = DebugKey.send(["key": .string("!"), "window": .string(controller.state.id)], services: services)
        } until: { _ in
            if case .terminal = pane.currentContent { return true }
            return false
        }
    }

    private static func run(_ services: AppServices, _ action: () -> Void, until done: @escaping (Double) -> Bool) async -> JSONValue {
        frames.start()
        BenchSpans.begin()
        let start = ContinuousClock.now
        action()
        let keyMilliseconds = BenchSpans.ms(.now - start)
        // Checked on each display-link frame (event-driven, no sleep): the change is visible,
        // then the bench window of frames after it, or 3 s.
        let visible = await frames.settled(until: { done(BenchSpans.ms(.now - start)) }, start: start,
                                        window: BenchSpans.ms(window), deadline: 3_000)
        let spans = BenchSpans.end()
        let stats = frames.stop()
        return .object([
            "key_ms": .number(keyMilliseconds),
            "visible_ms": visible.map { .number($0) } ?? .null,
            "main_thread_spans_ms": .number(spans.reduce(0) { $0 + $1.milliseconds }),
            "spans": .array(spans.map { .object(["name": .string($0.name), "at": .number($0.start), "ms": .number($0.milliseconds)]) }),
            "frames": stats,
        ])
    }
}

/// Display-link frame intervals between `start` and `stop`.
@MainActor
final class BenchFrames {
    private lazy var client = FrameClient(owner: "debug.new_tab.frames", isAnimation: false, on: .app) { [weak self] tick in
        self?.tick(tick)
        return true
    }
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var refresh: Double = 0
    private var waiter: Waiter?
    private var startedAt = ContinuousClock.now
    /// Ms from ``start()`` to the first display frame after it.
    private var firstTick: Double?

    private struct Waiter {
        var done: () -> Bool
        var start: ContinuousClock.Instant
        var window: Double
        var deadline: Double
        var visible: Double?
        var continuation: CheckedContinuation<Double?, Never>
    }

    /// Resumes with the ms at which `done` first held (checked each frame), once `window` ms of
    /// frames followed it, or nil at `deadline` ms.
    func settled(until done: @escaping () -> Bool, start: ContinuousClock.Instant, window: Double, deadline: Double) async -> Double? {
        await withCheckedContinuation { continuation in
            waiter = Waiter(done: done, start: start, window: window, deadline: deadline, continuation: continuation)
        }
    }

    func start() {
        last = 0
        startedAt = .now
        firstTick = nil
        intervals.removeAll(keepingCapacity: true)
        client.activate()
    }

    func stop() -> JSONValue {
        client.deactivate()
        let period = refresh * 1_000
        let missed = period > 0 ? intervals.filter { $0 > period * 1.5 }.count : 0
        return .object([
            "count": .number(Double(intervals.count)), "refresh_ms": .number(period),
            "max_ms": .number(intervals.max() ?? 0), "missed": .number(Double(missed)),
            "first_tick_ms": firstTick.map { .number($0) } ?? .null,
            "intervals_ms": .array(intervals.prefix(64).map { .number(($0 * 100).rounded() / 100) }),
        ])
    }

    private func tick(_ tick: FrameTick) {
        if let interval = tick.refreshInterval { refresh = interval }
        if firstTick == nil { firstTick = BenchSpans.ms(.now - startedAt) }
        if last > 0 { intervals.append((tick.timestamp - last) * 1_000) }
        last = tick.timestamp
        guard var waiting = waiter else { return }
        let now = BenchSpans.ms(.now - waiting.start)
        if waiting.visible == nil, waiting.done() { waiting.visible = now }
        if let visible = waiting.visible, now - visible >= waiting.window || now >= waiting.deadline {
            waiter = nil
            waiting.continuation.resume(returning: visible)
        } else if waiting.visible == nil, now >= waiting.deadline {
            waiter = nil
            waiting.continuation.resume(returning: nil)
        } else {
            waiter = waiting
        }
    }
}
#endif
