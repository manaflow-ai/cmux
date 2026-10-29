@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextMemory
import Foundation
import Testing

/// `debug.memory`'s source: ``MemorySnapshotModel/memorySnapshot(history:)`` over a
/// fake app (a real daemon store, faked cache, windows and pages) maps each tab's phase, kind and
/// processes, each workspace's mount state and terminal counts, an unattached surface as unknown
/// bytes, and reads no title, URL or path; ``MemoryPressureHistory`` keeps the applied level.
@MainActor @Suite struct MemorySnapshotModelTests {
    /// An app the test sets up: workspaces from a daemon store, the rest as plain values.
    @MainActor final class FakeApp: MemorySnapshotModel {
        let store = DaemonStore()
        var memoryReport = MemoryReport(level: .normal, mode: .medium,
                                        budget: .forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false), consumers: [])
        var kernelPressure = MemoryPressureLevel.normal
        var pressureOverride: MemoryPressureLevel?
        var memoryWorkspaces: [WorkspaceModel] { store.workspaces }
        var onScreen: Set<String> = []
        var parked: Set<String> = []
        var phases: [String: ContentLifecycle<String>.Phase] = [:]
        var surfaces: [String: MemoryTerminalSurface] = [:]
        var browsers: [String: MemoryBrowserContent] = [:]
        var agentPIDs: [String: Int32] = [:]
        var memoryTerminal = MemoryDiagnosticsSnapshot.Terminal(warmCapacity: 8, surfaces: 2, rendering: 1,
                                                                hiddenNonvolatileIOSurfaceBytes: nil, lastFrames: 0)
        var memorySpares: [MemoryDiagnosticsSnapshot.Spare] = []

        func workspaceMounts() -> (onScreen: Set<String>, parked: Set<String>) { (onScreen, parked) }
        func contentPhase(_ tabID: String) -> ContentLifecycle<String>.Phase { phases[tabID] ?? .unmounted }
        func terminalSurface(_ tabID: String) -> MemoryTerminalSurface? { surfaces[tabID] }
        func browserContent(_ tab: TabModel) -> MemoryBrowserContent {
            browsers[tab.id] ?? MemoryBrowserContent(chromium: false, processes: .none)
        }
        func agentChatProcess(_ tab: TabModel) -> Int32? { agentPIDs[tab.id] }
    }

    private static let history = MemoryPressureHistory.Snapshot(changes: [], levelSinceMilliseconds: 0)

    /// Three workspaces: a terminal, a browser page, an agent chat and an unattached terminal on screen;
    /// a crashed terminal parked; a browser tab with no page unmounted. Every tab has a title, a URL
    /// or a working directory the answer must not carry.
    private static func app() throws -> (FakeApp, tabs: [String], workspaces: [String]) {
        let app = FakeApp()
        var chat = TabSnapshot(surface: 3, kind: .conversation, title: "Secret chat")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:this-mac", session: "sess-1"))
        let panes = [
            [TabSnapshot(surface: 1, kind: .pty, title: "Secret shell", cwd: "/Users/someone/secret"),
             TabSnapshot(surface: 2, kind: .browser, title: "Private Mail", url: "https://example.com/inbox", browserEngine: "cef"),
             chat,
             TabSnapshot(surface: 4, kind: .pty, title: "Secret build")],
            [TabSnapshot(surface: 5, kind: .pty, title: "Secret logs")],
            [TabSnapshot(surface: 6, kind: .browser, title: "Private Bank", url: "https://bank.example.com")],
        ]
        let workspaces = panes.enumerated().map { index, tabs in
            let pane = PaneSnapshot(id: PaneID(rawValue: UInt64(index + 1)), tabs: tabs)
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(index + 1)), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: nil, name: "Secret project \(index)",
                                     screens: [screen])
        }
        app.store.apply(snapshot: DaemonTree(workspaces: workspaces))
        let workspaceIDs = app.store.workspaces.map(\.id)
        let tabIDs = app.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id)
        try #require(workspaceIDs.count == 3 && tabIDs.count == 6)
        app.onScreen = [workspaceIDs[0]]
        app.parked = [workspaceIDs[1]]
        app.phases = [tabIDs[0]: .mountedVisible, tabIDs[1]: .mountedHidden, tabIDs[2]: .mountedHidden,
                      tabIDs[3]: .unmounted, tabIDs[4]: .crashed]
        app.surfaces = [tabIDs[0]: MemoryTerminalSurface(estimateBytes: 4096, rendering: true),
                        tabIDs[3]: MemoryTerminalSurface(estimateBytes: nil, rendering: false)]
        app.browsers = [tabIDs[1]: MemoryBrowserContent(chromium: true, processes: .chromiumRendererClients([7]))]
        app.agentPIDs = [tabIDs[2]: 900]
        return (app, tabIDs, workspaceIDs)
    }

    @Test func mapsTabsWorkspacesAndTerminalCounts() throws {
        let (app, tabIDs, workspaceIDs) = try Self.app()
        let snapshot = app.memorySnapshot(history: Self.history)

        #expect(snapshot.tabs.map(\.key) == tabIDs)
        #expect(snapshot.tabs.map(\.kind) == [.terminal, .browser, .agent, .terminal, .terminal, .browser])
        #expect(snapshot.tabs.map(\.state) == [.live, .live, .live, .unmounted, .crashed, .unmounted])
        #expect(snapshot.tabs.map(\.visible) == [true, false, false, false, false, false])
        #expect(snapshot.tabs.map(\.engine) == [nil, .cef, .webkit, nil, nil, .webkit])
        #expect(snapshot.tabs.map(\.appBytes) == [4096, nil, nil, nil, nil, nil],
                "an unattached surface and a tab with no surface are unknown, never 0")
        #expect(snapshot.tabs[1].processes == [.chromiumRendererClient(7)])
        #expect(snapshot.tabs[2].processes == [.webContent(900)])
        #expect(snapshot.tabs[5].processes.isEmpty)
        #expect(snapshot.webContentPIDs == [900])

        #expect(snapshot.workspaces.map(\.id) == workspaceIDs)
        #expect(snapshot.workspaces.map(\.state) == [.mounted, .parked, .unmounted])
        #expect(snapshot.workspaces.map(\.terminalSurfaces) == [2, 0, 0], "the crashed terminal has no surface")
        #expect(snapshot.workspaces.map(\.renderingSurfaces) == [1, 0, 0])
        #expect(snapshot.workspaces.map(\.tabKeys) == [Array(tabIDs[0 ..< 4]), [tabIDs[4]], [tabIDs[5]]])
    }

    /// The model's titles, URLs and working directories never reach the answer; its workspace bytes
    /// come from its tabs' sampled processes.
    @Test func theAnswerHasNoTitleURLOrPath() throws {
        let (app, _, _) = try Self.app()
        let snapshot = app.memorySnapshot(history: Self.history)
        let processes = MemoryDiagnosticsProcesses(rows: [
            .init(kind: .chromiumRenderer, pid: 812, physFootprintBytes: 62_000_000),
            .init(kind: .webkitWebContent, pid: 900, physFootprintBytes: 40_000_000),
        ], rendererPIDs: [7: 812])
        let data = try MemoryDiagnosticsReport(snapshot: snapshot, processes: processes).jsonData()
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["Secret", "Private", "example.com", "/Users", "someone", "sess-1"] {
            #expect(!text.contains(secret), "\(secret) leaked")
        }
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let workspaces = try #require(json["workspaces"] as? [[String: Any]])
        #expect(workspaces.map { $0["bytes"] as? Int } == [4096 + 62_000_000 + 40_000_000, 0, 0])
        #expect(workspaces.map { $0["unknown_tabs"] as? Int } == [1, 1, 1])
    }

    /// A clock the test moves.
    final class TestClock {
        var now = Duration.zero
    }

    /// The history's level is the applied one: a kernel change under an override is a row but does not
    /// move `since`; clearing the override is an `override` row; an input that changes nothing is no row.
    @Test func historyFollowsTheAppliedLevel() {
        let kernel = ManualMemoryPressureSource()
        let clock = TestClock()
        let history = MemoryPressureHistory(pressure: MemoryPressureEvents(source: kernel)) { clock.now }

        clock.now = .milliseconds(1000)
        history.overrideDidChange(.critical)
        clock.now = .milliseconds(2000)
        kernel.send(.warning)
        #expect(history.changes.map(\.level) == [.normal, .critical, .critical])
        #expect(history.changes.map(\.kernelLevel) == [.normal, .normal, .warning])
        #expect(history.changes.map(\.source) == [.kernel, .override, .kernel])
        #expect(history.levelSinceMilliseconds == 1000, "the level has been critical since the override")

        clock.now = .milliseconds(3000)
        history.overrideDidChange(nil)
        #expect(history.changes.last == .init(atMilliseconds: 3000, kernelLevel: .warning, override: nil, source: .override))
        #expect(history.levelSinceMilliseconds == 3000)

        clock.now = .milliseconds(4000)
        kernel.send(.warning)
        history.overrideDidChange(nil)
        #expect(history.changes.count == 4, "an input that changes nothing is not a change")
        #expect(history.snapshot == .init(changes: history.changes, levelSinceMilliseconds: 3000))
    }

    @Test func historyKeepsTheLast32Changes() {
        let kernel = ManualMemoryPressureSource()
        let clock = TestClock()
        let history = MemoryPressureHistory(pressure: MemoryPressureEvents(source: kernel)) {
            clock.now += .milliseconds(250)
            return clock.now
        }
        for index in 0 ..< 40 { kernel.send(index.isMultiple(of: 2) ? .critical : .warning) }
        #expect(history.changes.count == MemoryPressureHistory.capacity)
        #expect(history.changes.last?.level == .warning)
        let times = history.changes.map(\.atMilliseconds)
        #expect(times == times.sorted())
        #expect(history.levelSinceMilliseconds == times.last)
    }
}
