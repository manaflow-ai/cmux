@testable import CmuxNextMacScreen
import CmuxNextDevices
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

// A screen tab a person opened (or `macScreen.open --autoconnect`) asks the hub at once, shown or not:
// a tab opened into a workspace not on screen used to wait for `tab <id> focus`. And `mac_screen.state`
// (`cmux app mac-screens --tab TAB`) reads one tab's state, scope and error.

nonisolated private let deviceID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddee02"

@MainActor
struct MacScreenUnseenConnectTests {
    private func makePages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
    }

    private func row(_ pages: MacScreenPages, tab: String) throws -> [String: CmuxNextSettings.JSONValue] {
        let answer = pages.stateAnswer(["tab": .string(tab)])
        return try #require(answer.objectValue?["tabs"]?.arrayValue?.first?.objectValue)
    }

    /// A person's open asks the hub before its tab is ever shown (no window, no view in one). With no
    /// hub signed in here, the ask comes back refused (not signed in) at once: proof it was asked.
    @Test func aPersonsTabAsksTheHubUnseen() throws {
        let pages = makePages()
        let record = pages.record(forDevice: deviceID, requesting: .view)
        // As `MacScreenPageService.open` does, before the tab is in any strip.
        pages.prepareOpen("a", record: record, byPerson: true)
        let hub = try #require(pages.tab("a")?.pane?.model.hub)
        #expect(pages.tab("a")?.view.window == nil, "never shown")
        #expect(hub.phase == .refused(.notSignedIn, requested: .view))
        pages.tabClosed("a")
    }

    /// Automation's open without `--autoconnect` (and a restored tab) still waits at Connect.
    @Test func anAutomationTabWaitsForConnect() throws {
        let pages = makePages()
        pages.prepare("a", record: pages.record(forDevice: deviceID), byPerson: false)
        pages.startConnecting("a")
        #expect(pages.tab("a") == nil, "no view made ahead of time")
        _ = pages.makeView(for: "a")
        let hub = try #require(pages.tab("a")?.pane?.model.hub)
        #expect(hub.phase == .idle)
        #expect(try row(pages, tab: "a")["state"]?.stringValue == "idle")
        pages.tabClosed("a")
    }

    /// Two tabs opened on the same device before either made its view each keep the scope asked for it:
    /// the second open does not replace (or take) the first's.
    @Test func twoTabsOnOneDeviceKeepTheirScopes() throws {
        let pages = makePages()
        let full = pages.record(forDevice: deviceID, requesting: .full)
        pages.prepare("a", record: full, byPerson: true)
        let view = pages.record(forDevice: deviceID, requesting: .view)
        pages.prepare("b", record: view, byPerson: true)
        pages.startConnecting("b")
        pages.startConnecting("a")
        #expect(pages.tab("a")?.pane?.model.hub?.phase == .refused(.notSignedIn, requested: .full))
        #expect(pages.tab("b")?.pane?.model.hub?.phase == .refused(.notSignedIn, requested: .view))
        pages.tabClosed("a")
        pages.tabClosed("b")
    }

    /// The state read: the tab's one state, the hub's phase and scope, the card's error text, and the
    /// store tab id, by which `--tab` finds it too.
    @Test func theStateReadNamesStateScopeAndError() throws {
        let pages = makePages()
        pages.events.storeTabID = { $0 == "a" ? "tab-42" : nil }
        pages.prepare("a", record: pages.record(forDevice: deviceID, requesting: .view), byPerson: true)
        pages.startConnecting("a")
        let refused = try row(pages, tab: "tab-42")
        #expect(refused["tab"]?.stringValue == "a")
        #expect(refused["store_tab"]?.stringValue == "tab-42")
        #expect(refused["state"]?.stringValue == "refused")
        #expect(refused["hub_phase"]?.stringValue == "refused")
        #expect(refused["scope"]?.stringValue == "view")
        let error = try #require(refused["error"]?.stringValue)
        #expect(error.contains("Not Signed In") && error.contains("Sign in to cmux"))
        // The frame size and time to first frame stay in the same row.
        #expect(refused["frame"]?.stringValue != nil && refused["first_frame_ms"] == CmuxNextSettings.JSONValue.null)
        pages.tabClosed("a")
    }

    /// The one state follows the hub until its stream runs, then the session, and reads `viewing`
    /// only with a picture up.
    @Test func theStateNamesEachStep() {
        typealias P = MacScreenPages
        #expect(P.stateName(hub: .idle, session: .ended, hasFrame: false) == "idle")
        #expect(P.stateName(hub: .requesting(.view), session: .ended, hasFrame: false) == "requesting")
        #expect(P.stateName(hub: .waitingForApproval(sessionID: "s", scope: .view), session: .ended, hasFrame: false) == "waiting_for_approval")
        #expect(P.stateName(hub: .approved(sessionID: "s", scope: .view), session: .ended, hasFrame: false) == "connecting")
        #expect(P.stateName(hub: .streaming(sessionID: "s", scope: .view), session: .connecting, hasFrame: false) == "connecting")
        #expect(P.stateName(hub: .streaming(sessionID: "s", scope: .view), session: .connected, hasFrame: false) == "waiting_for_frame")
        #expect(P.stateName(hub: .streaming(sessionID: "s", scope: .full), session: .connected, hasFrame: true) == "viewing")
        #expect(P.stateName(hub: .streamFailed(sessionID: "s", scope: .view), session: .ended, hasFrame: false) == "failed")
        #expect(P.stateName(hub: .declined(.view), session: .ended, hasFrame: false) == "declined")
        #expect(P.stateName(hub: .revoked(reason: nil), session: .ended, hasFrame: false) == "revoked")
        #expect(P.stateName(hub: .ended(reason: nil), session: .ended, hasFrame: false) == "ended")
        #expect(P.stateName(hub: nil, session: .connected, hasFrame: true) == "viewing")
        #expect(P.stateName(hub: nil, session: nil, hasFrame: false) == "not_started")
    }
}
