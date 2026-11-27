#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextAgentPane
import CmuxNextControl
import CmuxNextPages

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

    /// `bench_settings`: Cmd-, in window `window` (Settings opens late, 2026-11-15). `tab_ms`: a pane's strip (any: an inactive
    /// app may keep the focus in Home's dock) first selects a Settings tab it hosts; `visible_ms`: that page drew (no paint hold over it) at its size.
    static func settings(_ controller: WindowController, _ services: AppServices) async -> JSONValue {
        var tab: Double?, page: PageWebView?
        let claims = services.pageHostPool.claims.count
        let result = await run(services) {
            _ = DebugKey.send(["key": .string(","), "modifiers": .array([.string("command")]), "window": .string(controller.state.id)], services: services)
        } until: { at in
            guard let pane = controller.content?.panes.values.first(where: { ($0.view.content as? InternalPageView)?.page == .settings && $0.currentTabKey != nil
                    && $0.stripModel.selectedID?.rawValue == $0.currentTabKey }), let view = pane.view.content as? InternalPageView else { return false }
            if tab == nil { tab = at }
            page = view.content as? PageWebView
            return page?.hasPainted == true && pane.view.paintHold.kept == nil && view.window != nil && view.alphaValue > 0.99
        }
        guard case .object(var fields) = result else { return result }
        fields["tab_ms"] = tab.map { .number($0) } ?? .null
        fields["engine"] = .string(page.map { $0.showsChromium ? "cef" : "webkit" } ?? "none")
        fields["spare"] = .bool(services.pageHostPool.claims.count > claims && services.pageHostPool.claims.last?.spare == true)
        fields["claim"] = page?.lastClaim.map { .string($0.path.rawValue) } ?? .null
        return .object(fields)
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
#endif
