@testable import CmuxNextControl
import CmuxNextMetrics
import CmuxNextSettings
import CmuxNextSignposts
import CmuxNextTrace
import Foundation
import Testing

/// Automation latency (p09-observability task 115): each socket request is one `control.request` scope from its
/// line to its reply, with the CLI's flow, its method, source and class, and the `automation.request.<class>`
/// histogram; an app older than the `flow` field ignores it.
extension ControlSocketServerTests {
    /// A runtime that records the `control` category into `ring` and its histograms into a fresh store.
    static func recordingRuntime(_ ring: TraceRing) -> (TraceRuntime, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        _ = runtime.attach(ring)
        runtime.setCategoryMask(1 << UInt64(SignpostCategory.control.traceBit))
        let profile = MetricsProfile(appVersion: "1.0", buildNumber: "7", channel: "test", osVersion: "26.0", hardwareClass: "Mac16,10",
                                     buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 27))
        let store = MetricsStore(role: .app, profile: profile, pid: 4242, catalog: HistogramID.MethodClass.allCases.map(HistogramID.automationRequest)
            + [.automationMainQueue, .automationBlockedPerson])
        #expect(store.attach(to: runtime))
        return (runtime, store)
    }

    /// The scope's records (bit 63 of `arg0`) of `phase`, without the queue's own `control.request` slice (task 042).
    static func scopeRecords(_ image: TraceRing.Image, _ phase: TraceRecord.Phase) -> [TraceRecord] {
        image.records.filter {
            $0.name == SignpostName.controlRequest.rawValue && $0.phase == phase && $0.arg0 & ControlRequestScope.marker != 0
        }
    }

    @Test func threeCLICallsDecodeAsThreeFlowsWithTheirMethodSourceAndClass() throws {
        let ring = TraceRing(records: 4096, role: .app)
        let (runtime, store) = Self.recordingRuntime(ring)
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        router.updateCatalog(sampleCatalog())
        let server = ControlSocketServer(configuration: .init(path: temporarySocketPath(), accessMode: .automation), router: router,
                                         trace: runtime)
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: server.configuration.path)
        let flows: [UInt64] = [(4_321 << 32) | 1, (4_322 << 32) | 1, (4_323 << 32) | 1]
        for (index, flow) in flows.enumerated() {
            let line = JSONValue.object(["id": JSONValue(index), "method": "system.ping", "params": [:], "flow": JSONValue(Int(flow))])
            let reply = try JSONValue.parse(Data(client.send(line.compactText).utf8))
            #expect(reply["ok"] == true)
        }

        let image = try #require(ring.decodedImage())
        let starts = Self.scopeRecords(image, .flowOut)
        #expect(starts.map(\.arg1) == flows, "each call starts its own flow, in order")
        let begins = Self.scopeRecords(image, .asyncBegin)
        let ends = Self.scopeRecords(image, .asyncEnd)
        #expect(begins.count == 3)
        #expect(Set(begins.map(\.arg1)).count == 3)
        #expect(Set(begins.map(\.arg1)) == Set(ends.map(\.arg1)), "a guard or the reply ends every scope")
        let classCode = UInt64(try #require(HistogramID.MethodClass.allCases.firstIndex(of: .query))) + 1
        let descriptor = ControlRequestScope.methodID("system.ping") | UInt64(ControlRequestScope.Source.cli.rawValue) << 32 | classCode << 40
        for end in ends {
            #expect(end.arg0 & 0xFFFF_FFFF_FFFF == descriptor)
            #expect(end.arg0 >> 48 & 0xFF == UInt64(ControlRequestScope.Outcome.ok.rawValue))
        }
        let parsed = Self.scopeRecords(image, .instant).filter { $0.arg0 >> 56 & 0x7F == UInt64(ControlRequestScope.Mark.parsed.rawValue) }
        #expect(parsed.count == 3)

        let query = store.totals().histograms.first { $0.name == "automation.request.query" }
        #expect(query?.count == 3, "each request's accept-to-reply time is one sample of its class")
    }

    @Test func oldAppsIgnoreTheFlowField() async throws {
        let plain = #"{"id":1,"method":"system.ping","params":{"x":1}}"#
        let flowing = #"{"id":1,"method":"system.ping","params":{"x":1},"flow":18556553723905}"#
        let without = try ControlWire.decode(plain).get()
        let with = try ControlWire.decode(flowing).get()
        #expect(with.method == without.method)
        #expect(with.params == without.params, "the flow is a top-level field: params stay as sent")
        #expect(with.id == without.id)
        #expect(with.flow == 18_556_553_723_905)
        #expect(without.flow == nil)
        // Any other shape is ignored, never refused.
        for shape in [#""7""#, "-1", "0", "1.5", "9007199254740992", "null", "true"] {
            let line = #"{"id":1,"method":"system.ping","flow":"# + shape + "}"
            #expect(try ControlWire.decode(line).get().flow == nil, "flow \(shape)")
        }
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        let flowingReply = await router.response(forLine: flowing)
        let plainReply = await router.response(forLine: plain)
        #expect(flowingReply == plainReply, "the reply is the same with or without a flow")
    }

    @Test func aScopeReleasedWithoutAReplyEndsAsAbandoned() throws {
        let ring = TraceRing(records: 256, role: .app)
        let (runtime, store) = Self.recordingRuntime(ring)
        do {
            let scope = ControlRequestScope(connection: ControlConnectionID(rawValue: 9), runtime: runtime)
            scope.parsed(ControlRequest(method: "snapshot.get"), connection: ControlConnectionID(rawValue: 9))
        }
        do {
            let scope = ControlRequestScope(connection: ControlConnectionID(rawValue: 9), runtime: runtime)
            scope.noteResult(ok: false)
            scope.replied()
            scope.replied()
        }

        let image = try #require(ring.decodedImage())
        let begins = Self.scopeRecords(image, .asyncBegin)
        let ends = Self.scopeRecords(image, .asyncEnd)
        try #require(begins.count == 2)
        #expect(begins.allSatisfy { $0.arg0 & 0xFFFF_FFFF == 9 })
        #expect(ends.map(\.arg1) == begins.map(\.arg1), "each scope ends once")
        #expect(ends.map { $0.arg0 >> 48 & 0xFF } == [UInt64(ControlRequestScope.Outcome.abandoned.rawValue),
                                                       UInt64(ControlRequestScope.Outcome.failed.rawValue)])
        let reads = store.totals().histograms.first { $0.name == "automation.request.query" }
        #expect(reads?.count == 1, "only a request whose method decoded is a sample")
    }

    @Test func aQueuedRequestMarksQueuedThenDispatchedWithItsMainThreadWait() async throws {
        let ring = TraceRing(records: 1024, role: .app)
        let (runtime, store) = Self.recordingRuntime(ring)
        let frames = ManualFrameSource()
        let queue = MainActorWorkQueue(frameSource: frames, trace: runtime)
        let connection = ControlConnectionID(rawValue: 2)
        let scope = ControlRequestScope(connection: connection, runtime: runtime)
        scope.parsed(ControlRequest(method: "action.run", flow: 77), connection: connection)
        async let value: Int = queue.run(connection: connection, method: "action.run", deadline: ContinuousClock.now + .seconds(30),
                                         scope: scope) { 7 }
        while queue.stats.pending < 1 { await Task.yield() }
        while queue.stats.executed < 1 { await frames.fire() }
        #expect(try await value == 7)
        scope.replied()

        let image = try #require(ring.decodedImage())
        let marks = Self.scopeRecords(image, .instant).map { UInt8(truncatingIfNeeded: $0.arg0 >> 56 & 0x7F) }
        #expect(marks == [ControlRequestScope.Mark.parsed, .queued, .dispatched].map(\.rawValue))
        #expect(Self.scopeRecords(image, .flowOut).map(\.arg1) == [77])
        let totals = store.totals().histograms
        #expect(totals.first { $0.name == "automation.main_queue_us" }?.count == 1)
        #expect(totals.first { $0.name == "automation.request.topology" }?.count == 1)
    }

    @Test func requestsAreClassedAndSourced() {
        #expect(ControlRequestScope.methodClass("browser.page.eval") == .browser)
        #expect(ControlRequestScope.methodClass("action.run") == .topology)
        #expect(ControlRequestScope.methodClass("debug.key") == .terminalIO)
        #expect(ControlRequestScope.methodClass("session.transfer.pull") == .cloud)
        #expect(ControlRequestScope.methodClass("feed.list") == .agent)
        #expect(ControlRequestScope.methodClass("file.open") == .create)
        #expect(ControlRequestScope.methodClass("snapshot.get") == .query)
        #expect(ControlRequestScope.methodClass("settings.set") == .other)
        let socket = ControlConnectionID(rawValue: 3)
        #expect(ControlRequestScope.Source(ControlRequest(method: "action.run"), connection: socket) == .cli)
        #expect(ControlRequestScope.Source(ControlRequest(method: "action.run", params: ["origin": "mcp"]), connection: socket) == .mcp)
        let agent = ControlRequest(method: "action.run", params: ["origin": "mcp", "caller": ["agent_session": "s1"]])
        #expect(ControlRequestScope.Source(agent, connection: socket) == .agent)
        #expect(ControlRequestScope.Source(ControlRequest(method: "action.run"), connection: .inProcess) == .app)
    }
}
