import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Leo 2026-10-29: "i also like the way it just loads in the subagent stuff instantly :(" / "as in
/// i want ours to load fast too :(". Opening an existing chat (a sidebar click, Open in Tab, a
/// subagent's pane) built a new page, which loaded, connected and attached cold, while the
/// prewarmed, connected New Tab page waited for the next Cmd-T. Such a tab now adopts that page
/// and switches it to the chat in place; the page stays out of sight behind the pane's cover
/// until it drew the chat, so its New Tab screen never shows in the chat's pane.
@MainActor @Suite(.serialized)
struct SpareSessionAdoptionTests {
    static let thisMac = "install:spare-session-adoption-test"

    /// A tab store as the App wires it: tab records in a tree, pages on a loopback port nobody serves.
    static func run(records: [String: AgentSessionRef]) -> AgentTabStore {
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(),
                                 environment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9/"], showcase: true)
        tabs.localHost = thisMac
        let tree = DaemonStore()
        tabs.lookup = { key in records[key].map { ($0, tree) } }
        return tabs
    }

    static func chat(_ session: String) -> AgentSessionRef {
        AgentSessionRef(host: thisMac, hostName: "This Mac", session: session, harness: "claude")
    }

    /// The pool's spare once it answered its handshake and drew its New Tab page.
    static func connectedSpare(of tabs: AgentTabStore) async throws -> AgentPaneView {
        let spare = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        let reply = await spare.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
        try #require(reply["value"] is [String: Any], "\(reply)")
        _ = await spare.model.respond(to: AgentPaneRequest(body: ["method": "pane.painted"]))
        _ = await spare.model.respond(to: AgentPaneRequest(body: ["method": "pane.clientReady", "params": ["ready": true]]))
        try #require(spare.model.hasHandshake && spare.model.hasPainted && spare.model.clientReady)
        return spare
    }

    /// The page says when its acpmux client is connected (`pane.clientReady`); a new handshake (a
    /// reload, a reconnect) starts it over. Reporting it touches nothing: the spare stays untouched.
    @Test func thePageReportsItsClientReady() async throws {
        let tabs = Self.run(records: [:])
        let spare = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        #expect(AgentPaneRequest(body: ["method": "pane.clientReady", "params": ["ready": true]]) == .clientReady(true))
        #expect(AgentPaneRequest(body: ["method": "pane.clientReady", "params": [:]]) == .unsupported("pane.clientReady"))
        _ = await spare.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
        #expect(!spare.model.clientReady)
        _ = await spare.model.respond(to: AgentPaneRequest(body: ["method": "pane.clientReady", "params": ["ready": true]]))
        #expect(spare.model.clientReady)
        #expect(!spare.model.userTouched, "a ready report counted as the person's touch")
        _ = await spare.model.respond(to: AgentPaneRequest(body: ["method": "pane.clientReady", "params": ["ready": false]]))
        #expect(!spare.model.clientReady)
        _ = await spare.model.respond(to: AgentPaneRequest(body: ["method": "pane.clientReady", "params": ["ready": true]]))
        _ = await spare.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
        #expect(!spare.model.clientReady, "a new handshake kept the old connection's ready")
    }

    /// HQ#5914 finding 1: every sidebar open refused the spare as "touched by dictation": the
    /// composer's mount reports whether its harness takes audio, which is no touch of the person's.
    @Test func theComposersAudioReportLeavesTheSpareUntouched() async throws {
        let tabs = Self.run(records: [:])
        let spare = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        _ = await spare.model.respond(to: AgentPaneRequest(body: ["method": "dictation.audio", "params": ["enabled": true]]))
        #expect(!spare.model.userTouched, "touched by \(spare.model.touchedBy ?? "?")")
        _ = await spare.model.respond(to: AgentPaneRequest(body: ["method": "dictation.toggle"]))
        #expect(spare.model.userTouched, "starting dictation is the person's touch")
    }

    /// HQ#5914 finding 1, review of #27759: a spare whose client is still connecting is not taken
    /// for an existing chat (the open would wait behind its chat list), nor in Low Power Mode or
    /// at serious thermal state (each open would make another page).
    @Test func whichSpareServesAChat() {
        func serves(handshake: Bool = true, painted: Bool = true, clientReady: Bool = true, lowPower: Bool = false,
                    thermal: ProcessInfo.ThermalState = .nominal) -> Bool {
            NewTabSparePool.servesChat(handshake: handshake, painted: painted, clientReady: clientReady,
                                       lowPower: lowPower, thermal: thermal)
        }
        #expect(serves())
        #expect(serves(thermal: .fair))
        #expect(!serves(handshake: false))
        #expect(!serves(painted: false))
        #expect(!serves(clientReady: false))
        #expect(!serves(lowPower: true))
        #expect(!serves(thermal: .serious))
        #expect(!serves(thermal: .critical))
    }

    @Test func anExistingChatOpensOnTheConnectedSpare() async throws {
        let tabs = Self.run(records: ["tab_chat": Self.chat("s-chat")])
        let spare = try await Self.connectedSpare(of: tabs)
        var taken = 0
        tabs.takeConnectedSpare = {
            taken += 1
            return spare
        }
        var scripts: [String] = []
        spare.evaluateScript = { scripts.append($0) }
        // A subagent's pane: the parent chat's tab, scrolled to the subagent's turn.
        tabs.revealTurn("subagent:sa-1", in: "tab_chat")

        let view = try #require(tabs.view(for: "tab_chat"))
        #expect(view === spare, "the chat's tab built a page of its own")
        #expect(taken == 1)
        #expect(tabs.existingView("tab_chat") === spare)
        #expect(view.model.sessionId == "s-chat")
        #expect(view.model.newTab == nil, "the adopted page still counts as a New Tab page")
        #expect(view.model.allowsTabConversion)
        #expect(tabs.pendingTurns["tab_chat"] == nil, "the subagent's turn stayed behind")
        let adopt = try #require(scripts.first { $0.contains("acpmux-session-adopt") }, "\(scripts)")
        #expect(adopt.contains("\"sessionId\":\"s-chat\""))
        #expect(adopt.contains("\"revealTurn\":\"subagent:sa-1\""))
        // Until it draws the chat: the pane's cover, and the page outside the window.
        #expect(!view.model.hasPainted, "the New Tab page's paint counted as the chat's")
        #expect(view.awaitsFirstPaint)
        #expect(view.showsLoadingState)
        #expect(view.holdsPageAway)
        #expect(view.pageContent.frame.maxX < 0 && view.pageContent.frame.maxY < 0, "\(view.pageContent.frame)")

        // The page drew the chat from the host's kept tail: it is back in place, in one frame.
        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.painted", "params": ["drewKeptTail": true]]))
        #expect(view.model.hasPainted)
        #expect(view.model.paintedFromKeptTail)
        #expect(!view.holdsPageAway)
        #expect(view.pageContent.frame.minX >= 0 && view.pageContent.frame.minY >= 0, "\(view.pageContent.frame)")
        #expect(view.loadingView.superview == nil, "the cover stayed over the drawn chat")
        #expect(view.loadingView.leftFading == false, "a chat drawn from a kept tail faded in")
    }

    /// Each exclusion keeps the tab's own page, and the spare stays in the pool.
    @Test func chatsWhoseOpenNeedsTheirOwnHandshakeKeepTheirOwnPage() async throws {
        let tabs = Self.run(records: ["tab_wake": Self.chat("s-wake"), "tab_chief": Self.chat("s-chief")])
        let spare = try await Self.connectedSpare(of: tabs)
        var taken = 0
        tabs.takeConnectedSpare = {
            taken += 1
            return spare
        }
        // A composer kept from a hibernated page reaches the page with its handshake.
        tabs.wakeStates["tab_wake"] = AgentPaneWakeState(shell: true, shellText: "make")
        let wake = try #require(tabs.view(for: "tab_wake"))
        #expect(wake !== spare)
        // A chat the Chief home keeps runs in that home's acpmux, not the spare's.
        tabs.chiefKeepsSession = { $0 == "s-chief" }
        let chief = try #require(tabs.view(for: "tab_chief"))
        #expect(chief !== spare)
        #expect(chief.model.sessionId == "s-chief")
        #expect(taken == 0, "an excluded chat took the spare")
        #expect(spare.model.newTab != nil)
    }

    /// A spare still loading (no handshake yet) is no connected page: the tab gets its own page,
    /// and the spare goes back to the pool untouched.
    @Test func aSpareThatHasNotConnectedIsNotAdopted() async throws {
        let tabs = Self.run(records: ["tab_chat": Self.chat("s-chat")])
        let spare = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))
        tabs.takeConnectedSpare = { spare }
        var recycled: [AgentPaneView] = []
        tabs.recycle = { recycled.append($0); return true }
        let view = try #require(tabs.view(for: "tab_chat"))
        #expect(view !== spare)
        #expect(view.model.sessionId == "s-chat")
        #expect(recycled.count == 1 && recycled.first === spare)
        #expect(spare.model.sessionId == nil && spare.model.newTab != nil)
    }

    @Test func theDecision() {
        func adopts(local: Bool = true, kind: AgentPaneHostKind = .local, session: String? = "s", newTabPage: Bool = false,
                    seeded: Bool = false, wake: Bool = false, chief: Bool = false) -> String? {
            SpareSessionAdoption.session(local: local, kind: kind, session: session, newTabPage: newTabPage, seeded: seeded,
                                         wake: wake, chiefKeeps: { _ in chief })
        }
        #expect(adopts() == "s")
        #expect(adopts(local: false, kind: .remote) == nil)
        #expect(adopts(kind: .chief) == nil)
        #expect(adopts(session: nil) == nil)
        #expect(adopts(session: "") == nil)
        #expect(adopts(newTabPage: true) == nil)
        #expect(adopts(seeded: true) == nil)
        #expect(adopts(wake: true) == nil)
        #expect(adopts(chief: true) == nil)
    }
}
