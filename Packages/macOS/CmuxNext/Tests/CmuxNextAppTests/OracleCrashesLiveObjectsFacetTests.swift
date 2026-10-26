#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
@testable import CmuxNextBrowserTabs
@testable import CmuxNextDaemon
import CmuxNextOracle
import Foundation
import Testing

/// The oracle's `crashes` and `liveObjects` facets (p15-oracle-188). Crashes counts child exits by kind from the
/// records the app and the daemon already keep (Chromium's crash log, the previous run, `oracle-state` childExits);
/// a log that dropped records or a daemon without childExits is not-comparable, never a zero. Live objects counts
/// the owners' tables in the snapshot's turn. Neither adds an observer: the app's list builds them and nothing
/// runs until a snapshot asks. Run: `swift test --filter OracleCrashesLiveObjectsFacetTests`.
@MainActor @Suite(.serialized) struct OracleCrashesLiveObjectsFacetTests {
    private static func record(_ type: String, _ source: BrowserCrashRecord.Source, _ reason: BrowserProcessExit.Reason = .crashed,
                               code: Int? = 11) -> BrowserCrashRecord {
        BrowserCrashRecord(processType: type, reason: reason, code: code, source: source)
    }

    /// A renderer counts once, from CEF's per-tab record (the child monitor's record of the same process is skipped);
    /// an extension renderer counts as a renderer, the GPU process as gpu, any other helper as utility, and the run
    /// this launch follows as the browser. The daemon's kinds come from its childExits.
    @Test func eachRecordCountsOnceUnderItsKind() async throws {
        let previous = OracleCrashesFacet.PreviousEnd(signal: 11, raisedException: false)
        let records = [Self.record("renderer", .engine), Self.record("renderer", .process),
                       Self.record("extension", .process), Self.record("gpu-process", .process, .killed, code: 9),
                       Self.record("utility", .process, .abnormal, code: 256)]
        let app = try #require(OracleCrashesFacet.AppExits(previous: previous, records: records, total: records.count))
        #expect(app.exits.map(\.kind) == [.browser, .renderer, .renderer, .gpu, .utility])
        let facet = OracleCrashesFacet(app: { app }, daemon: { () async throws(OracleFacetError) -> [String: Int]? in
            ["holder": 2, "daemon": 1]
        })
        #expect(facet.facet == .crashes)
        let snapshot = try await OracleFacets([facet]).beginCapture([.crashes]).finish()
        let crashes = try #require(snapshot["crashes"])
        #expect(crashes["counts"] == ["renderer": 2, "gpu": 1, "browser": 1, "utility": 1, "daemon": 1, "holder": 2])
        guard case .array(let exits) = crashes["exits"] else { Issue.record("exits is not a list"); return }
        #expect(exits.first == ["kind": "browser", "reason": "crashed", "exitCode": 11])
        #expect(exits.last == ["kind": "utility", "reason": "abnormal", "exitCode": 256])
    }

    /// A ring that dropped records would undercount: not-comparable. So is a daemon with no childExits.
    @Test func aShortLogOrAnOlderDaemonIsNotComparable() async throws {
        let records = [Self.record("renderer", .engine)]
        #expect(OracleCrashesFacet.AppExits(previous: nil, records: records, total: 65) == nil)
        let dropped = OracleCrashesFacet(app: { nil }, daemon: { () async throws(OracleFacetError) -> [String: Int]? in [:] })
        let first = try await OracleFacets([dropped]).beginCapture([.crashes]).finish()
        #expect(first["crashes"]?["status"] == "not-comparable")
        #expect(first["crashes"]?["task"] == "p15-oracle-188")
        let older = OracleCrashesFacet(app: { OracleCrashesFacet.AppExits(exits: []) },
                                       daemon: { () async throws(OracleFacetError) -> [String: Int]? in nil })
        let second = try await OracleFacets([older]).beginCapture([.crashes]).finish()
        #expect(second["crashes"]?["status"] == "not-comparable")
    }

    /// Workspace models and holders come from the stores: a provisional workspace is no model yet, and a dead
    /// terminal, a browser tab or a second tab of the same terminal adds no holder.
    @Test func storeCountsAreModelsAndLiveTerminals() {
        _ = NSApplication.shared
        let store = DaemonStore()
        let tabs = [TabSnapshot(surface: SurfaceID(rawValue: 1), terminalID: TerminalID(rawValue: "t1")),
                    TabSnapshot(surface: SurfaceID(rawValue: 2), terminalID: TerminalID(rawValue: "t1")),
                    TabSnapshot(surface: SurfaceID(rawValue: 3), terminalID: TerminalID(rawValue: "t2"), dead: true),
                    TabSnapshot(surface: SurfaceID(rawValue: 4), kind: .browser)]
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, resourceID: ResourceID(rawValue: "ws_1"), name: "w1",
                              screens: [screen]),
        ]))
        let counts = OracleLiveObjectsFacet.Reading.storeCounts([store, DaemonStore()])
        #expect(counts.workspaceModels == 1)
        #expect(counts.holders == 1)
    }

    /// The app's list provides both facets. Building it starts nothing: no Chromium engine is built, and a
    /// snapshot of live objects before the daemon tree loads is not-comparable.
    @Test func theAppListProvidesBothAndBuildsNoEngine() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.crashes))
        #expect(facets.provided.contains(.liveObjects))
        let snapshot = try #require(try facets.beginCapture([.liveObjects]).completed)
        #expect(snapshot["liveObjects"]?["status"] == "not-comparable")
        #expect(services.cache.chromium.built == nil)
    }

    /// A loaded tree gives every count of the schema, and still builds no Chromium engine.
    @Test func aLoadedTreeGivesEveryCount() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: []))
        let snapshot = try #require(try services.makeOracleFacets().beginCapture([.liveObjects]).completed)
        let live = try #require(snapshot["liveObjects"])
        #expect(live["cefBrowsers"] == 0)
        #expect(live["workspaceModels"] == 0)
        guard case .object(let members) = live else { Issue.record("not an object"); return }
        #expect(Set(members.keys) == ["workspaceModels", "cefBrowsers", "pageViews", "terminals", "holders", "subscriptions", "tasks"])
        #expect(services.cache.chromium.built == nil)
    }
}
#endif
