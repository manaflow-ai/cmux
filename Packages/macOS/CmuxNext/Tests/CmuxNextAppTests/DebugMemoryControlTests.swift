import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextMemory
import CmuxNextSettings
import Foundation
import Testing

/// `debug.memory`: the keys of schemas/debug-memory/debug-memory.schema.json,
/// unknown counts as `null`, `mode`/`budget`/`consumers` in MemoryReport's own encoding, a shared
/// process in no tab's bytes, workspace bytes from their tabs, the model read on the main actor and
/// the processes sampled off it, the applied level's history, an override that `debug.memory` shows,
/// and a release router that serves it with no URL, title or path in the answer.
@MainActor @Suite(.serialized) struct DebugMemoryControlTests {
    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    /// The threads a closure ran on (true: main).
    nonisolated final class Threads: Sendable {
        private let lock = Mutex<[Bool]>([])
        func note() { lock.withLock { $0.append(Thread.isMainThread) } }
        var onMain: [Bool] { lock.withLock { $0 } }
    }

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let traits = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .readsAndWritesDisk, retention: .lossless,
        recreateCost: .notApplicable, releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)
    private static let budget = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)

    private static func snapshot(
        consumers: [MemoryReport.Consumer] = [], tabs: [MemoryDiagnosticsSnapshot.Tab] = [],
        workspaces: [MemoryDiagnosticsSnapshot.Workspace] = [], spares: [MemoryDiagnosticsSnapshot.Spare] = [],
        history: MemoryPressureHistory.Snapshot = .init(changes: [], levelSinceMilliseconds: 0)
    ) -> MemoryDiagnosticsSnapshot {
        MemoryDiagnosticsSnapshot(
            report: MemoryReport(level: .warning, mode: .medium, budget: budget, consumers: consumers),
            kernelLevel: .normal, override: .warning, history: history, tabs: tabs, workspaces: workspaces,
            terminal: .init(warmCapacity: 8, surfaces: 3, rendering: 1, hiddenNonvolatileIOSurfaceBytes: nil, lastFrames: 2),
            spares: spares)
    }

    private func router(allowsDebug: Bool = true, threads: Threads = Threads(),
                        rows: [MemoryDiagnosticsProcesses.Row] = [], renderers: [Int32: Int32] = [:], framed: Set<Int32>? = nil,
                        read: @escaping @MainActor @Sendable () -> MemoryDiagnosticsSnapshot?) -> ControlRouter {
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test",
                                                             tag: "test", processID: getpid()),
                                   executor: Executor(),
                                   configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: allowsDebug))
        router.register([DebugMemoryControl.memoryMethod(read: read, sample: { _ in
            threads.note()
            return MemoryDiagnosticsProcesses(rows: rows, rendererPIDs: renderers, rendererClientsWithFrames: framed)
        })])
        return router
    }

    private func call(_ router: ControlRouter, id: String = "1") async throws -> [String: JSONValue] {
        let reply = try await router.handle(ControlRequest(id: .string(id), method: "debug.memory")).get()
        return try #require(reply.objectValue)
    }

    /// The JSON a type encodes with its own `Encodable`, as `debug.memory` parses it.
    private func encoded(_ value: some Encodable) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONValue.parse(encoder.encode(value))
    }

    /// The schema document's root.
    private func schema() throws -> [String: JSONValue] {
        let data = try Data(contentsOf: Self.repoRoot.appending(path: "schemas/debug-memory/debug-memory.schema.json"))
        return try #require(JSONValue.parse(data).objectValue)
    }

    /// `value`'s keys are the schema node's required keys (the node's every property), in each object
    /// and array item down the tree.
    private func expectKeys(_ value: JSONValue, match node: [String: JSONValue], at path: String) {
        if let items = node["items"]?.objectValue, let array = value.arrayValue {
            for element in array { expectKeys(element, match: items, at: path + "[]") }
            return
        }
        guard let properties = node["properties"]?.objectValue, let object = value.objectValue else { return }
        let required = Set(node["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(Set(properties.keys) == required, "\(path): the schema lists a property it does not require")
        #expect(Set(object.keys) == required, "\(path)")
        for (key, child) in object {
            if let childNode = properties[key]?.objectValue { expectKeys(child, match: childNode, at: path + "." + key) }
        }
    }

    @Test func answersTheSchemaKeysWithUnknownAsNull() async throws {
        let consumer = MemoryReport.Consumer(name: "tab_thumbnails", traits: Self.traits, limit: MemoryLimit(percent: 50),
                                             footprintBytes: 8 << 20, volatileBytes: nil, entries: 41)
        let snapshot = Self.snapshot(
            consumers: [consumer],
            tabs: [.init(key: "tab-1", kind: .terminal, state: .live, visible: true, appBytes: 1000),
                   .init(key: "tab-2", kind: .browser, engine: .webkit, state: .discarded, visible: false)],
            workspaces: [.init(id: "ws-1", state: .mounted, panes: 1, terminalSurfaces: 1, renderingSurfaces: 1,
                               tabKeys: ["tab-1", "tab-2"])],
            spares: [.init(pool: "new_tab", processKind: .webkitWebContent, pid: nil)],
            history: .init(changes: [.init(atMilliseconds: 250, kernelLevel: .normal, override: .warning, source: .override)],
                           levelSinceMilliseconds: 250))
        let json = try await call(router(rows: [.init(kind: .app, pid: 501, physFootprintBytes: 361_000_000)]) { snapshot })

        let document = try schema()
        expectKeys(.object(json), match: document, at: "debug.memory")
        #expect(json["pressure"] == ["level": "warning", "kernel_level": "normal", "override": "warning", "since_ms": 250])
        // One schema for the memory report's data: `debug.memory` writes it as MemoryReport encodes it.
        let mode = try encoded(MemorySaverMode.medium)
        let budget = try encoded(Self.budget)
        let consumerJSON = try encoded(consumer)
        #expect(json["mode"] == mode)
        #expect(json["budget"] == budget)
        #expect(json["consumers"] == .array([consumerJSON]))
        let row = try #require(json["consumers"]?.arrayValue?.first?.objectValue)
        #expect(row["volatile_bytes"] == .null, "an unknown count is null, never 0")

        #expect(json["processes"] == [["kind": "app", "pid": 501, "phys_footprint_bytes": 361_000_000]])
        #expect(json["terminal"] == ["warm_capacity": 8, "surfaces": 3, "rendering": 1,
                                     "hidden_nonvolatile_iosurface_bytes": nil, "last_frames": 2])
        #expect(json["workspaces"] == [["id": "ws-1", "state": "mounted", "panes": 1, "terminal_surfaces": 1,
                                        "rendering_surfaces": 1, "tabs": 2, "bytes": 1000, "unknown_tabs": 1]])
        #expect(json["tabs"]?.arrayValue?.first == ["key": "tab-1", "kind": "terminal", "engine": nil, "state": "live",
                                                    "visible": true, "pids": [], "bytes": 1000])
        #expect(json["spares"] == [["pool": "new_tab", "process_kind": "webkit_webcontent", "pid": nil, "bytes": nil]])
        #expect(json["pressure_history"] == [["at_ms": 250, "level": "warning", "kernel_level": "normal",
                                              "override": "warning", "source": "override"]])
    }

    @Test func readsTheModelOnMainAndSamplesOffMain() async throws {
        let reads = Threads()
        let samples = Threads()
        let snapshot = Self.snapshot()
        _ = try await call(router(threads: samples) {
            reads.note()
            return snapshot
        })
        #expect(reads.onMain == [true])
        #expect(samples.onMain == [false])
    }

    /// The answer has the histograms the read copied, and a read adds no sample: three reads that
    /// each sample the processes leave one footprint sample, the emitter's.
    @Test func readsShowTheHistogramsAndRecordNothing() async throws {
        let pressure = MemoryPressureEvents(source: ManualMemoryPressureSource())
        let histograms = MemoryHistograms(pressure: pressure, discardKinds: ["browser"])
        histograms.recordFootprints(MemoryDiagnosticsProcesses(rows: [.init(kind: .app, pid: 501, physFootprintBytes: 300 << 20)]))
        let rows: [MemoryDiagnosticsProcesses.Row] = [
            .init(kind: .app, pid: 501, physFootprintBytes: 361 << 20),
            .init(kind: .chromiumRenderer, pid: 812, physFootprintBytes: 62 << 20),
        ]
        let snapshot = Self.snapshot()
        let memory = router(allowsDebug: false, rows: rows) {
            var read = snapshot
            read.histograms = histograms.snapshot()
            return read
        }
        for id in ["1", "2", "3"] {
            let json = try await call(memory, id: id)
            #expect(json["processes"]?.arrayValue?.count == 2, "the answer lost the sampled processes")
            let shown = try #require(json["histograms"]?.objectValue)
            #expect(shown["app_pmf_mb"]?.objectValue?["count"] == 1)
            #expect(shown["app_pmf_mb"]?.objectValue?["sum"] == 300)
            #expect(shown["renderer_pmf_mb"]?.objectValue?["count"] == 0)
            #expect(shown["discards_per_hour"]?.objectValue?.keys.sorted() == ["browser"])
        }
        #expect(histograms.snapshot().appFootprintMiB.count == 1, "a debug.memory read recorded a footprint")
    }

    @Test func answersNullOnceTheAppIsGone() async throws {
        let reply = try await router { nil }.handle(ControlRequest(id: "1", method: "debug.memory")).get()
        #expect(reply == .null)
    }

    /// A tab's own processes count in its bytes; a process two tabs share is in neither (unknown),
    /// as Chrome's Task Manager keeps a shared renderer on one row. A workspace adds up its tabs'
    /// known bytes and counts the others.
    @Test func sharedProcessesAreInNoTabsBytes() async throws {
        let snapshot = Self.snapshot(
            tabs: [
                .init(key: "own", kind: .browser, engine: .cef, state: .live, visible: false, processes: [.chromiumRendererClient(7)]),
                .init(key: "shared-a", kind: .browser, engine: .webkit, state: .live, visible: false, processes: [.webContent(900)]),
                .init(key: "shared-b", kind: .agent, engine: .webkit, state: .live, visible: false, processes: [.webContent(900)]),
                .init(key: "asleep", kind: .browser, engine: .webkit, state: .discarded, visible: false),
            ],
            workspaces: [.init(id: "ws-a", state: .mounted, panes: 2, tabKeys: ["own", "shared-a"]),
                         .init(id: "ws-b", state: .parked, panes: 1, tabKeys: ["shared-b", "asleep"])],
            spares: [.init(pool: "new_tab", processKind: .webkitWebContent, pid: 950)])
        #expect(snapshot.webContentPIDs == [900, 950])
        let rows: [MemoryDiagnosticsProcesses.Row] = [
            .init(kind: .chromiumRenderer, pid: 812, physFootprintBytes: 62_000_000),
            .init(kind: .webkitWebContent, pid: 900, physFootprintBytes: 40_000_000),
            .init(kind: .webkitWebContent, pid: 950, physFootprintBytes: 41_000_000),
        ]
        let json = try await call(router(rows: rows, renderers: [7: 812]) { snapshot })
        let tabs = try #require(json["tabs"]?.arrayValue).compactMap(\.objectValue)
        let byKey = Dictionary(uniqueKeysWithValues: tabs.map { ($0["key"]?.stringValue ?? "", $0) })
        #expect(byKey["own"]?["bytes"] == 62_000_000)
        #expect(byKey["own"]?["pids"] == [812])
        #expect(byKey["shared-a"]?["bytes"] == .null)
        #expect(byKey["shared-b"]?["bytes"] == .null)
        #expect(byKey["asleep"]?["state"] == "discarded")
        #expect(byKey["asleep"]?["bytes"] == .null)
        let workspaces = try #require(json["workspaces"]?.arrayValue).compactMap(\.objectValue)
        #expect(workspaces.compactMap { $0["bytes"] } == [62_000_000, 0])
        #expect(workspaces.compactMap { $0["unknown_tabs"] } == [1, 2])
        #expect(workspaces.compactMap { $0["state"] } == ["mounted", "parked"])
        #expect(json["spares"] == [["pool": "new_tab", "process_kind": "webkit_webcontent", "pid": 950, "bytes": 41_000_000]])
    }

    /// `spares` lists the Chromium spares by kind with process and bytes: a spare window
    /// by its placeholder's renderer (null with none), and each renderer helper that hosts no frame of any
    /// browser as `chromium_unattributed_renderer`, never as Chromium's spare. A renderer that hosts a frame
    /// of a browser that is no tab (a DevTools front end) is no such row, and extension renderers are none.
    @Test func listsChromiumSparesByKind() async throws {
        let snapshot = Self.snapshot(
            tabs: [.init(key: "tab", kind: .browser, engine: .cef, state: .live, visible: true, processes: [.chromiumRendererClient(7)])],
            spares: [.init(pool: "chromium_window", processKind: .chromiumRenderer, pid: nil, rendererClients: [3]),
                     .init(pool: "chromium_pages_window", processKind: .chromiumRenderer, pid: nil)])
        let rows: [MemoryDiagnosticsProcesses.Row] = [
            .init(kind: .chromiumRenderer, pid: 812, physFootprintBytes: 62_000_000),
            .init(kind: .chromiumRenderer, pid: 830, physFootprintBytes: 21_000_000),
            .init(kind: .chromiumRenderer, pid: 840, physFootprintBytes: 24_000_000),
            .init(kind: .chromiumRenderer, pid: 850, physFootprintBytes: 30_000_000),
            .init(kind: .chromiumRenderer, pid: 860, physFootprintBytes: 40_000_000),
        ]
        // 7: the tab, 3: the spare window's placeholder, 11: a DevTools front end (no tab), 9: no frame.
        let renderers: [Int32: Int32] = [7: 812, 3: 830, 9: 840, 11: 860]
        let json = try await call(router(rows: rows, renderers: renderers, framed: [7, 3, 11]) { snapshot })
        #expect(json["spares"] == [
            ["pool": "chromium_window", "process_kind": "chromium_renderer", "pid": 830, "bytes": 21_000_000],
            ["pool": "chromium_pages_window", "process_kind": "chromium_renderer", "pid": nil, "bytes": nil],
            ["pool": "chromium_unattributed_renderer", "process_kind": "chromium_renderer", "pid": 840, "bytes": 24_000_000],
        ])
        let document = try schema()
        let pools = document["properties"]?.objectValue?["spares"]?.objectValue?["items"]?.objectValue?["properties"]?
            .objectValue?["pool"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for spare in json["spares"]?.arrayValue ?? [] {
            #expect(pools.contains(spare.objectValue?["pool"]?.stringValue ?? ""), "\(spare) is no schema pool")
        }

        // A sample that did not read the renderers with frames (no Chromium, host mode) lists no unattributed one.
        let unread = try await call(router(rows: rows, renderers: renderers, framed: nil) { snapshot })
        #expect(unread["spares"]?.arrayValue?.count == 2)
    }

    /// The app's sample reads the renderers that host a frame on the main actor, after it
    /// listed the helpers off it, and carries that read: a renderer that started and committed its page
    /// between the model read and the helper list is in it, so it is no unattributed row.
    @Test func appSampleReadsTheFramedRenderersOnMainAfterTheHelpers() async {
        let threads = Threads()
        let processes = await AppMemoryModel.processes(Self.snapshot(), helperParent: getpid(), rendererClientsWithFrames: {
            threads.note()
            return [5]
        })
        #expect(threads.onMain == [true])
        #expect(processes.rendererClientsWithFrames == [5])
        #expect(processes.rows.first?.kind == .app)
    }

    /// A release router serves `debug.memory` (and drops other debug methods), and the answer has no
    /// URL, title or path even when an ID or a consumer name carries one.
    @Test func releaseServesItWithNoURLTitleOrPath() async throws {
        let snapshot = Self.snapshot(
            consumers: [MemoryReport.Consumer(name: "Quarterly Report - Draft", traits: Self.traits, limit: .default,
                                              footprintBytes: nil, volatileBytes: nil, entries: nil)],
            tabs: [.init(key: "https://example.com/private?q=1", kind: .browser, engine: .webkit, state: .live, visible: true)],
            workspaces: [.init(id: "/Users/someone/project", state: .mounted, panes: 1)])
        let release = router(allowsDebug: false) { snapshot }
        release.register([.async("debug.other") { _ in .null }])
        #expect(release.method(named: "debug.memory") != nil)
        #expect(release.method(named: "debug.other") == nil)

        let json = try await call(release)
        let text = JSONValue.object(json).compactText
        for secret in ["example.com", "https", "/Users", "someone", "Quarterly"] {
            #expect(!text.contains(secret), "\(secret) leaked")
        }
        #expect(json["tabs"]?.arrayValue?.first?.objectValue?["key"] == .string(MemoryDiagnosticsReport.redacted))
        #expect(json["consumers"]?.arrayValue?.first?.objectValue?["name"] == .string(MemoryDiagnosticsReport.redacted))
        let report = MemoryDiagnosticsReport(snapshot: snapshot, processes: MemoryDiagnosticsProcesses(rows: []))
        #expect(report.opaque("6F1C3A2B-0000-4000-8000-ABCDEF012345") == "6F1C3A2B-0000-4000-8000-ABCDEF012345")
        #expect(report.opaque("tab_thumbnails") == "tab_thumbnails")
        #expect(report.opaque("") == MemoryDiagnosticsReport.redacted)
        #expect(report.opaque(String(repeating: "a", count: 65)) == MemoryDiagnosticsReport.redacted)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.hibernation.pressure` then `debug.memory` on the app's own methods: the override is in
    /// `pressure` and in the last history row, and `since_ms` is the override's time; `none` is a row too.
    @Test func anOverrideShowsInPressureAndHistory() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil)
        router.register(DebugHibernationControl.methods(services))
        let held: MemoryPressureLevel = services.memoryCoordinator.kernelLevel == .critical ? .warning : .critical

        _ = try await router.handle(ControlRequest(id: "1", method: "debug.hibernation.pressure",
                                                   params: ["level": .string(held.rawValue)])).get()
        var json = try await call(router, id: "2")
        let pressure = try #require(json["pressure"]?.objectValue)
        #expect(pressure["level"] == .string(held.rawValue))
        #expect(pressure["override"] == .string(held.rawValue))
        var last = try #require(json["pressure_history"]?.arrayValue?.last?.objectValue)
        #expect(last["source"] == "override")
        #expect(last["override"] == .string(held.rawValue))
        #expect(last["level"] == .string(held.rawValue))
        #expect(pressure["since_ms"] == last["at_ms"])

        _ = try await router.handle(ControlRequest(id: "3", method: "debug.hibernation.pressure", params: ["level": "none"])).get()
        json = try await call(router, id: "4")
        #expect(json["pressure"]?.objectValue?["override"] == .null)
        last = try #require(json["pressure_history"]?.arrayValue?.last?.objectValue)
        #expect(last["source"] == "override")
        #expect(last["override"] == .null)
        #expect(last["level"] == .string(services.memoryCoordinator.kernelLevel.rawValue))
    }
    #endif
}
