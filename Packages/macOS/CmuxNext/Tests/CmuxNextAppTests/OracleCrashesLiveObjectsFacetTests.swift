#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextBrowser
@testable import CmuxNextBrowserTabs
@testable import CmuxNextDaemon
import CmuxNextOracle
import Foundation
import Testing

/// The oracle's `crashes` and `liveObjects` facets. Crashes counts child exits by kind from the
/// records the app and the daemon already keep (Chromium's crash log tallies, the previous run, `oracle-state`
/// childExits); a daemon that is lost or has no childExits is not-comparable, never a zero. Live objects counts
/// the owners' tables in the snapshot's turn. Neither adds an observer: the app's list builds them and nothing
/// runs until a snapshot asks. Run: `swift test --filter OracleCrashesLiveObjectsFacetTests`.
@MainActor @Suite(.serialized) struct OracleCrashesLiveObjectsFacetTests {
    private static func record(_ type: String, _ source: BrowserCrashRecord.Source, _ reason: BrowserProcessExit.Reason = .crashed,
                               code: Int? = 11, pid: Int32? = nil) -> BrowserCrashRecord {
        BrowserCrashRecord(processType: type, pid: pid, reason: reason, code: code, source: source)
    }

    private static func log(_ records: [BrowserCrashRecord]) -> BrowserCrashLog {
        let log = BrowserCrashLog()
        for record in records { log.append(record) }
        return log
    }

    /// A renderer counts once per process, from the child monitor's record: two tabs of one renderer (two CEF
    /// records, one process record with its pid) are one exit, as Chrome counts `RenderProcessExited`. An extension
    /// renderer counts as a renderer, the GPU process as gpu, any other helper as utility, and the run this launch
    /// follows as the browser. The daemon's kinds come from its childExits.
    @Test func eachProcessCountsOnceUnderItsKind() async throws {
        let previous = OracleCrashesFacet.PreviousEnd(signal: 11, raisedException: false)
        let log = Self.log([Self.record("renderer", .engine), Self.record("renderer", .engine),
                            Self.record("renderer", .process, pid: 41),
                            Self.record("extension", .process, pid: 42), Self.record("gpu-process", .process, .killed, code: 9),
                            Self.record("utility", .process, .abnormal, code: 256)])
        let app = OracleCrashesFacet.AppExits(previous: previous, tallies: log.tallies, records: log.records)
        #expect(app.counts == [.browser: 1, .renderer: 2, .gpu: 1, .utility: 1])
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

    /// The Chromium Host's end (`CEFRuntime.hostEnded`, processType chromium-host) is the end of Chromium's browser
    /// process, so it counts as the browser, as a kill step aimed at the browser expects.
    @Test func theChromiumHostCountsAsTheBrowser() {
        let log = Self.log([Self.record("chromium-host", .process, .killed, code: 9)])
        let app = OracleCrashesFacet.AppExits(previous: nil, tallies: log.tallies, records: log.records)
        #expect(app.counts == [.browser: 1])
        #expect(app.exits == [OracleCrashesFacet.Exit(kind: .browser, reason: "killed", exitCode: 9)])
    }

    /// A renderer that hosted no tab (a spare, or an orphan's) has only the process record, and still counts.
    @Test func aRendererWithNoTabCounts() {
        let log = Self.log([Self.record("renderer", .process, pid: 7)])
        #expect(OracleCrashesFacet.AppExits(previous: nil, tallies: log.tallies, records: log.records).counts == [.renderer: 1])
    }

    /// The counts come from the log's tallies, so they stay exact after the 64-record ring drops records.
    @Test func countsStayExactPastTheRing() {
        let log = Self.log((0..<(BrowserCrashLog.capacity + 6)).map { Self.record("renderer", .process, pid: Int32($0)) })
        #expect(log.records.count == BrowserCrashLog.capacity)
        let app = OracleCrashesFacet.AppExits(previous: nil, tallies: log.tallies, records: log.records)
        #expect(app.counts[.renderer] == BrowserCrashLog.capacity + 6)
        #expect(app.exits.count == BrowserCrashLog.capacity)
    }

    /// A daemon with no childExits, or one whose connection was lost (a kill step's reconnect), is not-comparable.
    @Test func aLostOrOlderDaemonIsNotComparable() async throws {
        let older = OracleCrashesFacet(app: { OracleCrashesFacet.AppExits(counts: [:], exits: []) },
                                       daemon: { () async throws(OracleFacetError) -> [String: Int]? in nil })
        let snapshot = try await OracleFacets([older]).beginCapture([.crashes]).finish()
        #expect(snapshot["crashes"]?["status"] == "not-comparable")
        #expect(snapshot["crashes"]?["task"] == "p15-oracle-188")
        let gone = OracleCrashesFacet(app: { nil }, daemon: { () async throws(OracleFacetError) -> [String: Int]? in [:] })
        let goneSnapshot = try await OracleFacets([gone]).beginCapture([.crashes]).finish()
        #expect(goneSnapshot["crashes"]?["status"] == "not-comparable")
        #expect(DaemonError.notConnected.isLostConnection)
        #expect(DaemonError.connectionClosed(reason: "eof").isLostConnection)
    }

    /// cefBrowsers counts the registered tabs and the browsers Chromium created that wait for a pane (a popup never
    /// adopted is the leak I18 catches), but not a closed one or a registered one twice.
    @Test func cefBrowsersCountWaitingOrphans() {
        var ledger = CEFAdoptionLedger()
        #expect(CEFEngine.liveBrowsers(registered: [1, 2], ledger: ledger, unplaced: []) == 2)
        ledger.enqueue(Orphan(browser: 3, window: 9))
        #expect(CEFEngine.liveBrowsers(registered: [1, 2], ledger: ledger, unplaced: [4, 2]) == 4)
        ledger.closedUnregistered(3)
        #expect(CEFEngine.liveBrowsers(registered: [1, 2], ledger: ledger, unplaced: [4]) == 3)
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
