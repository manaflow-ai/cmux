import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHibernation
import CmuxNextPages
import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// A hidden chat lets its page go after a minute and keeps what the page held that acpmux does not (its wake
/// state: the composer's chips, shell mode's command, the transcript's place and folds). A chat selected again
/// after that built a page of its own, because only a new page's handshake could hand the state back: the return
/// loaded, connected and attached cold while the pool's connected page waited.
///
/// The return now takes the pool's page, and the state goes with the adopt event (decision 2026-11-16). The state
/// is not gone before the page says that it applied it: until then the page's model keeps it, and each path that
/// builds or lets go of a page hands it on.
///
/// No wait of this suite polls. A release is waited for by its own event (the pane is told to let the page go, in
/// the release's own turn); a limit on the wall clock only ends a test that fails. The hidden time runs on the
/// clock the test moves.
@MainActor @Suite(.serialized, .closesItsWindows)
struct ChatReturnWakeTests {
    /// What the page of the chat held when it let go.
    static let left = AgentPaneWakeState(
        attachments: [AgentPaneWakeState.Attachment(id: "a1", kind: "image", name: "shot.png", mimeType: "image/png", size: 4, data: "iVBO")],
        shell: true, shellText: "git status", scrollAnchor: AgentPaneScrollAnchor(rowId: "row-12", offset: 40))

    /// A state whose one chip holds `bytes` bytes of file content.
    static func state(ofBytes bytes: Int) -> AgentPaneWakeState {
        AgentPaneWakeState(attachments: [AgentPaneWakeState.Attachment(
            id: "big", kind: "image", name: "big.png", mimeType: "image/png", size: Double(bytes), data: String(repeating: "A", count: bytes))])
    }

    /// The detail of the adopt event among `scripts` (`AgentPaneView.adoptSession`), as the page reads it.
    static func adoptDetail(in scripts: [String]) throws -> [String: Any] {
        let script = try #require(scripts.first { $0.contains("acpmux-session-adopt") }, "no adopt event: \(scripts.count) scripts")
        let start = try #require(script.range(of: "{detail: ")?.upperBound, "no detail in the adopt event")
        // The script ends `{detail: <json>}))`.
        let json = String(script[start...].dropLast(3))
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], "the detail is no JSON object")
    }

    /// The `wake` of the handshake that `view`'s page gets when it asks now (`ready`), nil when it carries none.
    static func handshakeWake(of view: AgentPaneView) async throws -> [String: Any]? {
        let reply = await view.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
        let handshake = try #require(reply["value"] as? [String: Any], "\(reply)")
        return handshake["wake"] as? [String: Any]
    }

    /// The hibernation rig with a page let go: chat `session` of tab `key` was hidden for 70 s, its page said that
    /// it held `held`, and the tab keeps that. No frame of the page is asked for (an idle release needs none).
    static func released(_ key: String, session: String, held: AgentPaneWakeState, in rig: AgentPageHibernationTests.Rig) async throws {
        let events = ChatSpareRefillTests.Events()
        rig.hibernation.wakeState = { _ in held }
        rig.hibernation.snapshot = { _ in nil }
        rig.hibernation.displace = { [unowned rig] in
            rig.displaced.append($0)
            events.note()
        }
        rig.hibernation.update(setting: .fallback, pressure: .normal)
        _ = try rig.hiddenChat(key, session: session)
        let before = rig.displaced.count
        rig.advance(minutes: 70.0 / 60)
        try await events.wait(until: { rig.displaced.count > before }) { "the hidden chat kept its page after 70 s" }
        try #require(rig.tabs.existingView(key) == nil, "the released chat still has its page")
    }

    /// The case of the decision: a chat selected again 70 s after it was hidden takes the pool's connected page,
    /// and what its last page held goes with the adopt event. The model keeps the state until the page says that
    /// it applied it; then it is handed out, once.
    @Test func aChatSelectedAgainAfterSeventySecondsTakesThePoolsPageWithWhatItHeld() async throws {
        let rig = AgentPageHibernationTests.Rig()
        defer { rig.window.closeAfterTest() }
        try await Self.released("tab_back", session: "s-back", held: Self.left, in: rig)
        try #require(rig.tabs.wakeStates["tab_back"] == Self.left, "the tab did not keep what its page held")

        let spare = try await SpareSessionAdoptionTests.connectedSpare(of: rig.tabs)
        rig.tabs.takeConnectedSpare = { spare }
        var scripts: [String] = []
        spare.evaluateScript = { scripts.append($0) }

        let view = try #require(rig.tabs.view(for: "tab_back"))
        try #require(view === spare, "the chat's return built a page of its own")
        #expect(view.model.sessionId == "s-back")

        // The adopt event carries the state in the handshake's shape, and the place the page left over the kept one.
        let detail = try Self.adoptDetail(in: scripts)
        let wake = try #require(detail["wake"] as? [String: Any], "the adopt event lost what the page held: \(detail.keys.sorted())")
        let attachments = try #require(wake["attachments"] as? [[String: Any]])
        #expect(attachments.map { $0["name"] as? String } == ["shot.png"])
        #expect(attachments.first?["data"] as? String == "iVBO")
        #expect(wake["shell"] as? Bool == true)
        #expect(wake["shellText"] as? String == "git status")
        let place = try #require(detail["scrollAnchor"] as? [String: Any], "the adopt event has no place: \(detail.keys.sorted())")
        #expect(place["rowId"] as? String == "row-12")
        #expect(place["offset"] as? Double == 40)

        // Not gone before the page says that it applied it: a paint report that says nothing of it keeps it.
        #expect(rig.tabs.wakeStates["tab_back"] == nil, "the tab kept a second copy of the state")
        #expect(view.model.pendingWake == Self.left, "the state is gone before the page applied it")
        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.painted", "params": ["drewKeptTail": true]]))
        #expect(view.model.pendingWake == Self.left, "a paint report that names no applied state removed it")

        // The page says that it applied the state, with a paint report: handed out, once.
        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.painted", "params": ["appliedWake": true]]))
        #expect(view.model.pendingWake == nil, "the applied state was not removed")
        #expect(view.model.handedWake == Self.left, "the applied state is not kept for a quit that the page does not answer")
        #expect(try await Self.handshakeWake(of: view) == nil, "a reload of the page got the applied state a second time")
    }

    /// The pool's page took the chat and dies before it drew (its process ended, or the adopt event never reached
    /// it): the page that loads again asks for its handshake, and that handshake hands the state, as a cold page's
    /// does.
    @Test func aPoolPageThatDiesBeforeItsPaintGetsTheStateWithItsNextHandshake() async throws {
        let tabs = SpareSessionAdoptionTests.run(records: ["tab_dies": SpareSessionAdoptionTests.chat("s-dies")])
        tabs.wakeStates["tab_dies"] = Self.left
        let spare = try await SpareSessionAdoptionTests.connectedSpare(of: tabs)
        tabs.takeConnectedSpare = { spare }
        spare.evaluateScript = { _ in }

        let view = try #require(tabs.view(for: "tab_dies"))
        try #require(view === spare, "the chat's return built a page of its own")
        // No paint report came. The page loads again and asks for its handshake.
        let wake = try #require(try await Self.handshakeWake(of: view), "the state is gone with the page that died")
        #expect(wake["shellText"] as? String == "git status")
        #expect((wake["attachments"] as? [[String: Any]])?.map { $0["name"] as? String } == ["shot.png"])
        #expect(try await Self.handshakeWake(of: view) == nil, "the state was handed out a second time")
    }

    /// The pool's page took the chat, the adopt event is lost (the page stays a New Tab page that drew nothing of
    /// the chat) and the chat is hidden again. The page that lets go answers that it holds nothing, which is true
    /// of a page that never applied the state: the tab keeps the state that was not applied, not that answer.
    @Test func aPoolPageLetGoBeforeItAppliedTheStateLeavesItWithTheTab() async throws {
        let rig = AgentPageHibernationTests.Rig()
        defer { rig.window.closeAfterTest() }
        try await Self.released("tab_lost", session: "s-lost", held: Self.left, in: rig)

        let spare = try await SpareSessionAdoptionTests.connectedSpare(of: rig.tabs)
        rig.tabs.takeConnectedSpare = { spare }
        // The adopt event goes nowhere.
        spare.evaluateScript = { _ in }
        let view = try #require(rig.tabs.view(for: "tab_lost"))
        try #require(view === spare, "the chat's return built a page of its own")
        rig.tabs.takeConnectedSpare = nil

        // Hidden again for 70 s; the page says that it holds nothing.
        try await Self.released("tab_lost", session: "s-lost", held: AgentPaneWakeState(), in: rig)
        #expect(rig.tabs.wakeStates["tab_lost"] == Self.left, "the state that the page never applied is gone")

        // The next return has no pool page: its own page gets the state with its handshake.
        let rebuilt = try #require(rig.tabs.view(for: "tab_lost"))
        #expect(rebuilt !== spare)
        let wake = try #require(try await Self.handshakeWake(of: rebuilt), "the rebuilt page's handshake lost the state")
        #expect(wake["shellText"] as? String == "git status")
    }

    /// The pool's page refuses the chat (it is no connected, untouched New Tab page any more): the tab gets a page
    /// of its own, and the state is still there for that page's handshake.
    @Test func aPoolPageThatRefusesLeavesTheStateForTheTabsOwnPage() async throws {
        let tabs = SpareSessionAdoptionTests.run(records: ["tab_refused": SpareSessionAdoptionTests.chat("s-refused")])
        tabs.wakeStates["tab_refused"] = Self.left
        // No handshake yet: the page refuses.
        let unready = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        var taken = 0
        tabs.takeConnectedSpare = {
            taken += 1
            return unready
        }
        var recycled: [AgentPaneView] = []
        tabs.recycle = { recycled.append($0); return true }

        let view = try #require(tabs.view(for: "tab_refused"))
        #expect(taken == 1, "the return did not ask the pool for its page")
        #expect(view !== unready)
        #expect(recycled.count == 1 && recycled.first === unready, "the page that refused did not go back to the pool")
        #expect(unready.model.pendingWake == nil, "the page that refused kept the tab's state")
        let wake = try #require(try await Self.handshakeWake(of: view), "the tab's own page lost the state")
        #expect(wake["shellText"] as? String == "git status")
        #expect(tabs.wakeStates["tab_refused"] == nil, "the tab kept a second copy of the state")
    }

    /// The adopt event is a script on the click's path, so a state it carries has a bound (1 MB of chip content).
    /// A state under it goes with the pool's page; a state over it gets a page of its own, whose handshake hands it
    /// over off that path. The pool's page stays in the pool then.
    @Test func aStateOverTheBoundGetsItsOwnPageAndOneUnderItThePoolsPage() async throws {
        let tabs = SpareSessionAdoptionTests.run(records: ["tab_small": SpareSessionAdoptionTests.chat("s-small"),
                                                             "tab_large": SpareSessionAdoptionTests.chat("s-large")])
        let small = Self.state(ofBytes: 500_000)
        let large = Self.state(ofBytes: 1_500_000)
        tabs.wakeStates["tab_small"] = small
        tabs.wakeStates["tab_large"] = large

        let spare = try await SpareSessionAdoptionTests.connectedSpare(of: tabs)
        var taken = 0
        tabs.takeConnectedSpare = {
            taken += 1
            return spare
        }
        spare.evaluateScript = { _ in }

        let own = try #require(tabs.view(for: "tab_large"))
        #expect(own !== spare, "a state over the bound went with the adopt event")
        #expect(taken == 0, "a state over the bound took the pool's page")
        #expect(own.model.pendingWake == large, "the tab's own page does not hold the large state for its handshake")

        let adopted = try #require(tabs.view(for: "tab_small"))
        #expect(adopted === spare, "a state under the bound built a page of its own")
        #expect(adopted.model.pendingWake == small)
    }
}
