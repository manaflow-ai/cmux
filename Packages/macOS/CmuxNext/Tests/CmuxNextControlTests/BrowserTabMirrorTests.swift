@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// One browser tab in two workspaces (user, 2026-10-25: "if a agent is using cua on a browser
/// like i see it on the right of the workspace"): `browser.page.mirror` lists an agent's tab in
/// Home's right column too, the tab an agent starts driving outside Home is mirrored there on
/// its first write, and `browser.page.right` reads the mirrored tab the column shows
/// (plans/cmux-next/shared-browser-tabs.md).
@Suite(.timeLimit(.minutes(1))) struct BrowserTabMirrorTests {
    struct NoEngine: BrowserPageEngine {
        func run(_ operation: BrowserPageOperation, tabID: String, url: String?) async throws -> JSONValue { [:] }
    }

    /// Records the app's mirror calls.
    final class RecordingMirrors: BrowserTabMirrorHost {
        struct Call: Equatable, Sendable {
            var tab: String
            var pane: String?
            var select: Bool
            var removes: Bool
        }

        let calls = Mutex<[Call]>([])
        var all: [Call] { calls.withLock { $0 } }
        var adds: [Call] { all.filter { !$0.removes } }

        func mirror(tab: String, into pane: String, select: Bool) async -> Bool {
            calls.withLock { $0.append(Call(tab: tab, pane: pane, select: select, removes: false)) }
            return true
        }

        func unmirror(tab: String, from pane: String?) async -> [String] {
            calls.withLock { $0.append(Call(tab: tab, pane: pane, select: false, removes: true)) }
            return pane.map { [$0] } ?? []
        }
    }

    /// Home (chat dock and right column) plus the agent's own workspace, whose pane holds
    /// the agent's browser tabs `tab_agent` and `tab_agent2`.
    static func snapshot(focusPane: String? = nil) -> ControlSnapshot {
        var snapshot = BrowserPageRightTests.homeSnapshot()
        for id in ["tab_agent", "tab_agent2"] {
            var tab = ControlTabInfo(id: id, surface: "7\(id.count)", kind: "browser", title: "Agent", url: "https://example.com/")
            tab.browserProfileID = BrowserPageService.agentBrowserProfileID
            snapshot.topology.workspaces[0].screens[0].panes[0].tabs.append(tab)
        }
        if let focusPane { snapshot.topology.focus = ControlFocus(paneID: focusPane, tabID: nil) }
        return snapshot
    }

    func install(_ snapshot: ControlSnapshot = Self.snapshot(), mirrors: RecordingMirrors? = RecordingMirrors()) -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: BrowserPageRightTests.OpeningExecutor())
        BrowserPageService(engine: NoEngine(), leases: BrowserTabLeases(), mirrors: mirrors).install(on: router)
        router.snapshots.publish { $0 = snapshot }
        return router
    }

    func call(_ router: ControlRouter, _ method: String, _ params: [String: JSONValue]) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(method: method, params: params))
    }

    @Test func mirrorListsTheTabInHomesRightColumnByDefault() async throws {
        let mirrors = RecordingMirrors()
        let router = install(mirrors: mirrors)
        let answer = try await call(router, "browser.page.mirror", ["tab": "tab_agent"]).get()
        #expect(answer["tab"] == "tab_agent")
        #expect(answer["pane"] == .string(BrowserPageRightTests.rightPane))
        #expect(answer["mirrored"] == true)
        #expect(mirrors.all == [.init(tab: "tab_agent", pane: BrowserPageRightTests.rightPane, select: true, removes: false)])
    }

    @Test func mirrorNamesAPaneAndOffTakesItOut() async throws {
        let mirrors = RecordingMirrors()
        let router = install(mirrors: mirrors)
        _ = try await call(router, "browser.page.mirror", ["tab": "tab_agent", "pane": .string(BrowserPageRightTests.dockPane)]).get()
        let off = try await call(router, "browser.page.mirror", ["tab": "tab_agent", "off": true]).get()
        #expect(off["mirrored"] == false)
        #expect(mirrors.all.map(\.removes) == [false, true])
        #expect(mirrors.all.first?.pane == BrowserPageRightTests.dockPane)
        #expect(mirrors.all.last?.pane == nil, "off with no pane takes the tab out of every pane")
    }

    @Test func aTabIsNeverMirroredIntoItsOwnPane() async {
        let mirrors = RecordingMirrors()
        let router = install(mirrors: mirrors)
        let refused = await call(router, "browser.page.mirror", ["tab": "tab_agent", "pane": "pane-1"])
        #expect(refused.failure?.code == "invalid_params")
        #expect(mirrors.all.isEmpty)
    }

    @Test func mirrorIsUnavailableWithoutAHost() async {
        let router = install(mirrors: nil)
        #expect(await call(router, "browser.page.mirror", ["tab": "tab_agent"]).failure?.code == "unavailable")
    }

    @Test func mirrorTakesNoLease() async throws {
        let router = install()
        _ = try await call(router, "browser.page.eval", ["tab": "tab_agent", "agent": "Muse", "script": "1"]).get()
        // The person (or Chief) shows a tab another agent drives: that is not driving it.
        _ = try await call(router, "browser.page.mirror", ["tab": "tab_agent", "agent": "Chief"]).get()
    }

    @Test func anAgentsFirstWriteOutsideHomeMirrorsItsTabIntoHomeOnce() async throws {
        let mirrors = RecordingMirrors()
        let router = install(mirrors: mirrors)
        _ = try await call(router, "browser.page.eval", ["tab": "tab_agent", "agent": "Muse", "script": "1"]).get()
        _ = try await call(router, "browser.page.eval", ["tab": "tab_agent", "agent": "Muse", "script": "2"]).get()
        #expect(mirrors.adds == [.init(tab: "tab_agent", pane: BrowserPageRightTests.rightPane, select: true, removes: false)])
    }

    @Test func anAgentsNextTabReplacesItsEarlierHomeMirror() async throws {
        let mirrors = RecordingMirrors()
        let router = install(mirrors: mirrors)
        _ = try await call(router, "browser.page.eval", ["tab": "tab_agent", "agent": "Muse", "script": "1"]).get()
        _ = try await call(router, "browser.page.eval", ["tab": "tab_agent2", "agent": "Muse", "script": "1"]).get()
        #expect(mirrors.all.map(\.tab) == ["tab_agent", "tab_agent", "tab_agent2"])
        #expect(mirrors.all.map(\.removes) == [false, true, false])
        #expect(mirrors.all.dropFirst().first?.pane == BrowserPageRightTests.rightPane)
    }

    @Test func theHomeMirrorStaysUnselectedWhileThePersonWorksInThatColumn() async throws {
        let mirrors = RecordingMirrors()
        let router = install(Self.snapshot(focusPane: BrowserPageRightTests.rightPane), mirrors: mirrors)
        _ = try await call(router, "browser.page.eval", ["tab": "tab_agent", "agent": "Muse", "script": "1"]).get()
        #expect(mirrors.adds.first?.select == false)
    }

    @Test func aTabAlreadyInHomeIsNotMirrored() async throws {
        let mirrors = RecordingMirrors()
        let router = install(mirrors: mirrors)
        _ = try await call(router, "browser.page.eval", ["tab": "tab_user", "agent": "Chief", "script": "1"]).get()
        // An unnamed request (the person's script) is not an agent: nothing mirrors either.
        _ = try await call(router, "browser.page.eval", ["tab": "tab_agent", "script": "1"]).get()
        #expect(mirrors.all.isEmpty)
    }

    @Test func rightReadsTheMirroredTabTheColumnShows() async throws {
        var snapshot = Self.snapshot()
        let right = snapshot.topology.workspaces[1].screens[0].panes.indices.last ?? 0
        snapshot.topology.workspaces[1].screens[0].panes[right].mirroredTabIDs = ["tab_agent"]
        snapshot.topology.workspaces[1].screens[0].panes[right].selectedTabID = "tab_agent"
        let router = install(snapshot)
        let answer = try await call(router, "browser.page.right", ["agent": "Chief", "verb": "browser.page.screenshot"]).get()
        #expect(answer["tab"] == "tab_agent")
        #expect(answer["shared"] == true)
    }

    @Test func paneJSONListsItsMirroredTabsOnlyWhenItHasSome() {
        var pane = ControlPaneInfo(id: "pane_x", handle: "1")
        #expect(pane.json["mirrored_tabs"] == nil)
        pane.mirroredTabIDs = ["tab_agent"]
        #expect(pane.json["mirrored_tabs"] == ["tab_agent"])
    }
}

extension BrowserTabMirrorTests {
    /// Review finding: the 90 s lease lapsed between two of the agent's steps, and its next write
    /// mirrored and selected the tab in Home again, though the person had closed that mirror.
    @Test func aMirrorThePersonClosedStaysClosedAfterTheAgentsPause() async throws {
        let mirrors = RecordingMirrors()
        let clock = BrowserPageLeaseTests.Clock()
        let router = ControlRouter(identity: testIdentity(), executor: BrowserPageRightTests.OpeningExecutor())
        BrowserPageService(engine: NoEngine(), leases: BrowserTabLeases(now: { clock.now }), mirrors: mirrors).install(on: router)
        router.snapshots.publish { $0 = Self.snapshot() }
        _ = try await call(router, "browser.page.eval", ["tab": "tab_agent", "agent": "Muse", "script": "1"]).get()
        clock.advance(.seconds(600))
        _ = try await call(router, "browser.page.eval", ["tab": "tab_agent", "agent": "Muse", "script": "2"]).get()
        #expect(mirrors.adds.count == 1)
    }
}
