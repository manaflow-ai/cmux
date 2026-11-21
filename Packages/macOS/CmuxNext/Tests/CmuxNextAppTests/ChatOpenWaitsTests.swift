@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Testing

/// A chat's open is judged by a count, not a time (decision 2026-11-16): the waits for another
/// process between the moment the tab gets its page and the page's first paint of the chat
/// (``AgentPaneOpenWaits``). The target is 0 for a chat whose kept tail a connected page draws and
/// 1 at most on a connected page, whatever the chat's length. A page made for the tab that reads
/// the chat from acpmux runs every wait in a row, which is what a person sees as a pane with no
/// content.
///
/// These tests play the page's part by its reports to the host; no page loads. They pin the count
/// the host gives each report (its model of the waits; it observes none of them). `open_waits` in
/// the readiness reply is this same model, fed by a real page's reports; what the page asked
/// acpmux is in `acp_log`.
///
/// Two limits of the model, which no test here covers. A page that shows the chat's copy from the
/// last launch reports its paint before its handshake; its count is 0 with no steps, so 0 is the
/// target only for an adopted page. And `connected` counts when its report came before the paint's
/// report, also when the paint did not wait for it (the page made for the tab with a kept tail
/// reads 3 below, because the test's page sends no `pane.clientReady`; a real one can read 5).
///
/// The last 2 tests pin the seam only (the 3 call sites and the type's rules); they are no proof
/// of the product's open path.
@MainActor @Suite(.serialized)
struct ChatOpenWaitsTests {
    /// The page's part of an open, by its reports: a page that never asked for its handshake asks;
    /// a chat with no kept tail needs the page's client connected, then its read; the page draws.
    /// A kept tail comes with the handshake or the adopt event, so the page draws it at once.
    static func draws(_ view: AgentPaneView, keptTail: Bool) async throws {
        if !view.model.hasHandshake {
            let reply = await view.model.respond(to: AgentPaneRequest(body: ["method": "ready"]))
            try #require(reply["value"] is [String: Any], "\(reply)")
        }
        if !keptTail, !view.model.clientReady {
            _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.clientReady", "params": ["ready": true]]))
        }
        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.painted", "params": ["drewKeptTail": keptTail]]))
        try #require(view.model.hasPainted)
    }

    /// A tab store whose pool holds one connected page, and the chat's page taken from it.
    static func chatOnTheConnectedPage() async throws -> AgentPaneView {
        let tabs = SpareSessionAdoptionTests.run(records: ["tab_chat": SpareSessionAdoptionTests.chat("s-chat")])
        let spare = try await SpareSessionAdoptionTests.connectedSpare(of: tabs)
        // The page's own load is not the chat's open: it ran, and was counted, before any tab asked.
        #expect(spare.model.openWaits.steps.contains(.handshake))
        tabs.takeConnectedSpare = { spare }
        let view = try #require(tabs.view(for: "tab_chat"))
        try #require(view === spare, "the chat's tab built a page of its own")
        #expect(view.model.openWaits == AgentPaneOpenWaits(), "the connected page's own load counted as the chat's open")
        return view
    }

    @Test func aChatWithAKeptTailOnAConnectedPageWaitsForNoProcess() async throws {
        let view = try await Self.chatOnTheConnectedPage()
        try await Self.draws(view, keptTail: true)
        #expect(view.model.openWaits.steps == [])
        #expect(view.model.openWaits.count == 0)
    }

    @Test func aChatWithNoKeptTailOnAConnectedPageWaitsForItsReadOnly() async throws {
        let view = try await Self.chatOnTheConnectedPage()
        try await Self.draws(view, keptTail: false)
        #expect(view.model.openWaits.steps == [.attached])
        #expect(view.model.openWaits.count == 1)
    }

    /// What the two targets are measured against: the page made for a tab, with no page to adopt.
    @Test func aPageMadeForTheTabRunsEveryWait() async throws {
        let tabs = SpareSessionAdoptionTests.run(records: ["tab_read": SpareSessionAdoptionTests.chat("s-read"),
                                                           "tab_tail": SpareSessionAdoptionTests.chat("s-tail")])
        let read = try #require(tabs.view(for: "tab_read"))
        try await Self.draws(read, keptTail: false)
        #expect(read.model.openWaits.steps == [.handshake, .connected, .attached])
        #expect(read.model.openWaits.count == 6)
        // A kept tail saves the connection and the read, not the page's own load.
        let tail = try #require(tabs.view(for: "tab_tail"))
        try await Self.draws(tail, keptTail: true)
        #expect(tail.model.openWaits.steps == [.handshake])
        #expect(tail.model.openWaits.count == 3)
    }

    @Test func onlyWhatRanBeforeTheFirstPaintCounts() {
        var waits = AgentPaneOpenWaits()
        waits.ran(.handshake)
        waits.ran(.handshake)
        #expect(waits.steps == [.handshake], "a step counted twice")
        // A page with no chat (a New Tab page) reads nothing before it draws.
        waits.paint(chat: false, fromKeptTail: false)
        #expect(waits.count == 3)
        // The client connects after the page drew: the person waited for nothing of it.
        waits.ran(.connected)
        waits.paint(chat: true, fromKeptTail: false)
        #expect(waits.steps == [.handshake])
    }
}
