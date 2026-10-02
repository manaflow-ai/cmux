import Foundation
import Testing
@testable import CmuxNextApps

/// The JavaScriptCore prototype engine driving the real runtime and samples.
struct AppEngineTests {
    private func engine(_ manifest: AppManifest, _ directory: URL, granted: Set<String>? = nil, sink: RecordingSink,
                        clock: any AppEngineClock = ManualAppClock(), events: AppEventHub = AppEventHub(),
                        output: OutputCollector) -> AppEngine {
        AppEngine(configuration: AppEngineConfiguration(
            manifest: manifest, bundleDirectory: directory, grantedScopes: granted ?? Set(manifest.scopes.map(\.scope)),
            sink: sink, events: events, clock: clock, output: output.sink))
    }

    nonisolated static let agents: AppJSON = [
        ["id": "a1", "state": "blocked", "terminal_id": "term_1", "source": "claude", "updated_at_ms": 0, "extra": ["name": "fix tests"]],
        ["id": "a2", "state": "working", "terminal_id": "term_2", "source": "codex", "updated_at_ms": 0],
    ]

    @Test func runningAgentsSampleRendersRowsFromAgentList() async throws {
        let (manifest, directory) = try TestApps.sample("running-agents")
        let sink = RecordingSink { request in
            request.op == "agent.list" ? .success(AppOperationResult(value: Self.agents)) : .failure(.unsupported(request.op))
        }
        let output = OutputCollector()
        let engine = engine(manifest, directory, sink: sink, output: output)
        try await engine.start()
        #expect(await engine.mount("m1", export: "renderAgents") == nil)
        #expect(await eventually {
            output.scene("m1").nodes.values.contains { $0.type == .row && $0.string("title") == "fix tests" }
        })
        let scene = output.scene("m1")
        #expect(scene.root != nil)
        #expect(scene.nodes.values.contains { $0.type == .row && $0.flag("unread") && $0.flag("onTap") })
        #expect(sink.requests.first?.op == "agent.list")
        #expect(sink.requests.first?.params["machine"] == "current")
        #expect(sink.requests.first?.origin == .script)
        await engine.stop()
    }

    @Test func tapHandlerOpsCarryUserOriginAndMutationsGetIdempotencyKeys() async throws {
        let (manifest, directory) = try TestApps.sample("running-agents")
        let sink = RecordingSink { request in
            switch request.op {
            case "agent.list": .success(AppOperationResult(value: Self.agents))
            case "terminal.get": .success(AppOperationResult(value: ["terminal_id": "term_1", "tab_id": "tab_9"]))
            case "tab.focus": .success(AppOperationResult(value: true))
            default: .failure(.unsupported(request.op))
            }
        }
        let output = OutputCollector()
        let engine = engine(manifest, directory, sink: sink, output: output)
        try await engine.start()
        await engine.mount("m1", export: "renderAgents")
        #expect(await eventually { output.scene("m1").nodes.values.contains { $0.string("title") == "fix tests" } })
        let row = try #require(output.scene("m1").nodes.first { $0.value.string("title") == "fix tests" }?.key)
        await engine.dispatch("m1", node: row, event: "tap")
        #expect(await eventually { sink.requests.contains { $0.op == "tab.focus" } })
        let get = try #require(sink.requests.first { $0.op == "terminal.get" })
        #expect(get.origin == .user)
        #expect(get.idempotencyKey == nil)
        let focus = try #require(sink.requests.first { $0.op == "tab.focus" })
        #expect(focus.params["tab"] == "tab_9")
        #expect(focus.idempotencyKey?.isEmpty == false)
        await engine.stop()
    }

    @Test func missingScopesAreRefusedBeforeTheSink() async throws {
        let (manifest, directory) = try TestApps.bundle(main: """
            async function probe() { try { await cmux.call("workspace.list", {}) ; return "ran" } catch (e) { return e.code } }
            // Bypasses the runtime's courtesy filter: the host must refuse too.
            function raw() { __cmuxAppNative.call("workspace.list", "{}", "{}", 424242); return true }
            return { probe, raw }
            """)
        let sink = RecordingSink()
        let engine = engine(manifest, directory, granted: [], sink: sink, output: OutputCollector())
        try await engine.start()
        #expect(await engine.runCommand("probe") == .success("scope.missing"))
        #expect(await engine.runCommand("raw") == .success(true))
        _ = await engine.runCommand("probe")
        #expect(sink.requests.isEmpty)
        await engine.stop()
    }

    @Test func timersFireOnTheInjectedClockAndClearCancels() async throws {
        let (manifest, directory) = try TestApps.bundle(main: """
            let fired = 0
            function arm() { cmux.timer.after(500, () => { fired += 1 }); const t = cmux.timer.after(500, () => { fired += 100 }); cmux.timer.clear(t); return true }
            function count() { return fired }
            return { arm, count }
            """)
        let clock = ManualAppClock()
        let engine = engine(manifest, directory, sink: RecordingSink(), clock: clock, output: OutputCollector())
        try await engine.start()
        _ = await engine.runCommand("arm")
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: .milliseconds(499))
        #expect(await engine.runCommand("count") == .success(0))
        clock.advance(by: .milliseconds(1))
        #expect(await eventually { await engine.runCommand("count") == .success(1) })
        #expect(await engine.counts.timers == 0)
        await engine.stop()
    }

    @Test func eventsReRunLiveQueries() async throws {
        let (manifest, directory) = try TestApps.sample("agent-status")
        let sink = RecordingSink { request in .success(AppOperationResult(value: request.op == "agent.list" ? Self.agents : .null)) }
        let events = AppEventHub()
        let output = OutputCollector()
        let engine = engine(manifest, directory, sink: sink, events: events, output: output)
        try await engine.start()
        await engine.mount("s", export: "renderStatus")
        #expect(await eventually { output.scene("s").nodes.values.contains { $0.string("text") == "1 working · 1 waiting" } })
        #expect(events.activeStreams.contains("agent.changed"))
        events.post("agent.changed")
        #expect(await eventually { sink.requests.filter { $0.op == "agent.list" }.count == 2 })
        await engine.stop()
        #expect(events.activeStreams.isEmpty)
    }

    @Test func aRunawayEvaluationStopsTheVM() async throws {
        let (manifest, directory) = try TestApps.bundle(main: "function spin() { for (;;) {} } return { spin }")
        let output = OutputCollector()
        let engine = engine(manifest, directory, sink: RecordingSink(), output: output)
        try await engine.start()
        // macOS JavaScriptCore exports the limit; without it the VM would spin forever here.
        try #require(await engine.hasWatchdog)
        _ = await engine.runCommand("spin")
        #expect(await engine.state == .stopped(AppEngine.limitReason))
        #expect(output.outputs.contains(.stopped(reason: AppEngine.limitReason)))
    }

    @Test func renderErrorsComeBackFromMount() async throws {
        let (manifest, directory) = try TestApps.bundle(main: "function bad() { throw new Error('nope') } return { bad }")
        let engine = engine(manifest, directory, sink: RecordingSink(), output: OutputCollector())
        try await engine.start()
        #expect(await engine.mount("m", export: "bad") == "nope")
        #expect(await engine.mount("m", export: "missing")?.contains("missing") == true)
        await engine.stop()
    }

    @Test func githubPRsFallsBackToNetFetchWhenTheIntegrationIsNotGranted() async throws {
        let (manifest, directory) = try TestApps.sample("github-prs")
        let sink = RecordingSink()
        let output = OutputCollector()
        let engine = AppEngine(configuration: AppEngineConfiguration(
            manifest: manifest, bundleDirectory: directory, grantedScopes: Set(manifest.scopes.map(\.scope)),
            settings: ["login": "octocat", "showDrafts": true], sink: sink, clock: ManualAppClock(), output: output.sink))
        try await engine.start()
        await engine.mount("p", export: "renderPRs")
        #expect(await eventually { sink.requests.contains { $0.op == "net.fetch" } })
        #expect(sink.requests.first { $0.op == "net.fetch" }?.params["url"]?.stringValue?.hasPrefix("https://api.github.com/search/issues") == true)
        #expect(!sink.requests.contains { $0.op == "integration.request" })
        #expect(await eventually { output.scene("p").nodes.values.contains { $0.type == .emptyState } })
        await engine.stop()
    }
}
