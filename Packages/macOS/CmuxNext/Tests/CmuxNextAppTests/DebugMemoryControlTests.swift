import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextControl
import CmuxNextMemory
import CmuxNextSettings
import Foundation
import Testing

/// `debug.memory` (p07-memory 010, memory-DESIGN.md section 7): the JSON keys of the design, unknown
/// counts as `null`, a shared process in no tab's bytes, the model read on the main actor and the
/// processes sampled off it, the last 32 pressure changes, and a release router that serves it with
/// no URL, title or path in the answer.
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

    private static let traits = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .readsAndWritesDisk, retention: .lossless,
        recreateCost: .notApplicable, releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    private static func snapshot(
        consumers: [MemoryReport.Consumer] = [], tabs: [MemoryDiagnosticsSnapshot.Tab] = [],
        workspaces: [MemoryDiagnosticsSnapshot.Workspace] = [], spares: [MemoryDiagnosticsSnapshot.Spare] = [],
        history: [MemoryPressureHistory.Change] = []
    ) -> MemoryDiagnosticsSnapshot {
        MemoryDiagnosticsSnapshot(
            report: MemoryReport(level: .warning, mode: .medium,
                                 budget: .forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false), consumers: consumers),
            kernelLevel: .normal, override: .warning, history: history, tabs: tabs, workspaces: workspaces,
            terminal: .init(warmCapacity: 8, surfaces: 3, gpuResidentCount: 1, hiddenNonvolatileIOSurfaceBytes: 4096, lastFrames: 2),
            spares: spares)
    }

    private func router(allowsDebug: Bool = true, threads: Threads = Threads(),
                        rows: [MemoryDiagnosticsProcesses.Row] = [], renderers: [Int32: Int32] = [:],
                        read: @escaping @MainActor @Sendable () -> MemoryDiagnosticsSnapshot?) -> ControlRouter {
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test",
                                                             tag: "test", processID: getpid()),
                                   executor: Executor(),
                                   configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: allowsDebug))
        router.register([DebugHibernationControl.memoryMethod(read: read, sample: { _ in
            threads.note()
            return MemoryDiagnosticsProcesses(rows: rows, rendererPIDs: renderers)
        })])
        return router
    }

    private func call(_ router: ControlRouter) async throws -> [String: JSONValue] {
        let reply = try await router.handle(ControlRequest(id: "1", method: "debug.memory")).get()
        return try #require(reply.objectValue)
    }

    /// A history whose clock moves 250 ms per recorded change.
    private func makeHistory(_ source: ManualMemoryPressureSource = ManualMemoryPressureSource()) -> MemoryPressureHistory {
        var now = Duration.zero
        return MemoryPressureHistory(pressure: MemoryPressureEvents(source: source)) {
            now += .milliseconds(250)
            return now
        }
    }

    @Test func answersTheDesignKeysWithUnknownAsNull() async throws {
        let snapshot = Self.snapshot(
            consumers: [MemoryReport.Consumer(name: "tab_thumbnails", traits: Self.traits, limit: MemoryLimit(percent: 50),
                                              footprintBytes: 8 << 20, volatileBytes: nil, entries: 41)],
            tabs: [.init(id: "tab-1", kind: .terminal, state: .live, visible: true, appBytes: 1000)],
            workspaces: [.init(id: "ws-1", mounted: true, parked: false, panes: 1, terminalSurfaces: 1,
                               gpuResidentSurfaces: 1, appBytes: 1000)])
        let json = try await call(router(rows: [.init(kind: .app, pid: 501, physFootprintBytes: 361_000_000)]) { snapshot })

        #expect(Set(json.keys) == ["pressure", "mode", "budget", "consumers", "processes", "tabs", "workspaces",
                                   "terminal", "spares", "pressure_history"])
        #expect(json["pressure"] == ["level": "warning", "kernel_level": "normal", "override": "warning", "since_ms": nil])
        #expect(json["mode"] == "medium")
        let budget = try #require(json["budget"]?.objectValue)
        #expect(budget["physical_bytes"] == JSONValue(16 << 30))
        #expect(budget["chromium_renderer_limit"] == 64)
        #expect(Set(budget.keys) == ["physical_bytes", "gpu_resident_available", "chromium_renderer_limit",
                                     "warm_terminal_surfaces", "parked_workspaces", "parked_idle_timeout_s",
                                     "image_cache_bytes", "home_render_bitmap_bytes", "hibernation_snapshot_bytes",
                                     "live_hidden_agent_pages", "live_hidden_internal_pages",
                                     "kitty_image_bytes_per_surface", "web_process_pages_per_group"])

        let consumer = try #require(json["consumers"]?.arrayValue?.first?.objectValue)
        #expect(consumer["name"] == "tab_thumbnails")
        #expect(consumer["managed"] == true)
        #expect(consumer["limit_percent"] == 50)
        #expect(consumer["footprint_bytes"] == JSONValue(8 << 20))
        #expect(consumer["volatile_bytes"] == .null, "an unknown count is null, never 0")
        #expect(consumer["entries"] == 41)
        #expect(consumer["traits"] == ["estimated_usage": "medium", "data_access": "reads_and_writes_disk",
                                       "retention": "lossless", "recreate_cost": "not_applicable",
                                       "release_cpu_cost": "low", "is_stateful": true, "supports_memory_limit": true])

        #expect(json["processes"] == [["kind": "app", "pid": 501, "phys_footprint_bytes": 361_000_000]])
        #expect(json["terminal"] == ["warm_capacity": 8, "warm_count": 2, "gpu_resident_count": 1,
                                     "hidden_nonvolatile_iosurface_bytes": 4096, "last_frames": 2])
        #expect(json["workspaces"] == [["id": "ws-1", "mounted": true, "parked": false, "panes": 1, "terminal_surfaces": 1,
                                        "gpu_resident_surfaces": 1, "app_bytes": 1000]])
        #expect(json["tabs"] == [["id": "tab-1", "kind": "terminal", "engine": nil, "state": "live", "visible": true,
                                  "pids": [], "footprint_bytes": 1000]])
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

    @Test func answersNullOnceTheAppIsGone() async throws {
        let reply = try await router { nil }.handle(ControlRequest(id: "1", method: "debug.memory")).get()
        #expect(reply == .null)
    }

    /// A tab's own processes count in its bytes; a process two tabs share is in neither (unknown),
    /// as Chrome's Task Manager keeps a shared renderer on one row.
    @Test func sharedProcessesAreInNoTabsBytes() async throws {
        let snapshot = Self.snapshot(
            tabs: [
                .init(id: "own", kind: .browser, engine: .cef, state: .live, visible: false, processes: [.chromiumRendererClient(7)]),
                .init(id: "shared-a", kind: .browser, engine: .webkit, state: .live, visible: false, processes: [.webContent(900)]),
                .init(id: "shared-b", kind: .agent, engine: .webkit, state: .live, visible: false, processes: [.webContent(900)]),
                .init(id: "asleep", kind: .browser, engine: .webkit, state: .discarded, visible: false),
            ],
            spares: [.init(pool: "new_tab", processKind: .webkitWebContent, pid: 950)])
        #expect(snapshot.webContentPIDs == [900, 950])
        let rows: [MemoryDiagnosticsProcesses.Row] = [
            .init(kind: .chromiumRenderer, pid: 812, physFootprintBytes: 62_000_000),
            .init(kind: .webkitWebContent, pid: 900, physFootprintBytes: 40_000_000),
            .init(kind: .webkitWebContent, pid: 950, physFootprintBytes: 41_000_000),
        ]
        let json = try await call(router(rows: rows, renderers: [7: 812]) { snapshot })
        let tabs = try #require(json["tabs"]?.arrayValue).compactMap(\.objectValue)
        let byID = Dictionary(uniqueKeysWithValues: tabs.map { ($0["id"]?.stringValue ?? "", $0) })
        #expect(byID["own"]?["footprint_bytes"] == 62_000_000)
        #expect(byID["own"]?["pids"] == [812])
        #expect(byID["shared-a"]?["footprint_bytes"] == .null)
        #expect(byID["shared-b"]?["footprint_bytes"] == .null)
        #expect(byID["asleep"]?["state"] == "discarded")
        #expect(byID["asleep"]?["footprint_bytes"] == .null)
        #expect(json["spares"] == [["pool": "new_tab", "process_kind": "webkit_webcontent", "pid": 950, "bytes": 41_000_000]])
    }

    /// A release router serves `debug.memory` (and drops other debug methods), and the answer has no
    /// URL, title or path even when an ID or a consumer name carries one.
    @Test func releaseServesItWithNoURLTitleOrPath() async throws {
        let snapshot = Self.snapshot(
            consumers: [MemoryReport.Consumer(name: "Quarterly Report - Draft", traits: Self.traits, limit: .default,
                                              footprintBytes: nil, volatileBytes: nil, entries: nil)],
            tabs: [.init(id: "https://example.com/private?q=1", kind: .browser, engine: .webkit, state: .live, visible: true)],
            workspaces: [.init(id: "/Users/someone/project", mounted: true, parked: false, panes: 1)])
        let release = router(allowsDebug: false) { snapshot }
        release.register([.async("debug.other") { _ in .null }])
        #expect(release.method(named: "debug.memory") != nil)
        #expect(release.method(named: "debug.other") == nil)

        let json = try await call(release)
        let text = JSONValue.object(json).compactText
        for secret in ["example.com", "https", "/Users", "someone", "Quarterly"] {
            #expect(!text.contains(secret), "\(secret) leaked")
        }
        #expect(json["tabs"]?.arrayValue?.first?.objectValue?["id"] == .string(MemoryDiagnosticsReport.redacted))
        #expect(json["consumers"]?.arrayValue?.first?.objectValue?["name"] == .string(MemoryDiagnosticsReport.redacted))
        let report = MemoryDiagnosticsReport(snapshot: snapshot, processes: MemoryDiagnosticsProcesses(rows: []))
        #expect(report.opaque("6F1C3A2B-0000-4000-8000-ABCDEF012345") == "6F1C3A2B-0000-4000-8000-ABCDEF012345")
        #expect(report.opaque("tab_thumbnails") == "tab_thumbnails")
        #expect(report.opaque("") == MemoryDiagnosticsReport.redacted)
        #expect(report.opaque(String(repeating: "a", count: 65)) == MemoryDiagnosticsReport.redacted)
    }

    /// The history keeps the last 32 changes, skips a level that repeats the last change, and records
    /// the debug override apart from the kernel's level.
    @Test func historyKeepsTheLast32Changes() {
        let pressure = ManualMemoryPressureSource()
        let history = makeHistory(pressure)
        #expect(history.changes.map(\.level) == [.normal])
        pressure.send(.normal)
        #expect(history.changes.count == 1, "a repeated level is not a change")
        pressure.send(.warning)
        history.record(.critical, source: .override)
        #expect(history.changes.suffix(2).map(\.source) == [.kernel, .override])
        for index in 0 ..< 40 { pressure.send(index.isMultiple(of: 2) ? .critical : .warning) }
        #expect(history.changes.count == MemoryPressureHistory.capacity)
        #expect(history.changes.last?.level == .warning)
        let times = history.changes.map(\.atMilliseconds)
        #expect(times == times.sorted())
    }

    @Test func pressureHistoryIsInTheAnswer() async throws {
        let pressure = ManualMemoryPressureSource()
        let history = makeHistory(pressure)
        pressure.send(.warning)
        let changes = history.changes
        let json = try await call(router { Self.snapshot(history: changes) })
        #expect(json["pressure_history"] == [["at_ms": 250, "level": "normal", "source": "kernel"],
                                             ["at_ms": 500, "level": "warning", "source": "kernel"]])
        #expect(json["pressure"]?.objectValue?["since_ms"] == 500)
    }
}
