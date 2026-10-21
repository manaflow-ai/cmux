import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-6bgzj on the host a chat actually opens on. `ChatScrollRestoreTests` covers the shared page
/// host (``AgentPageProvider``), but `agent.pageHost` is off by default, so an agent pane's page
/// talks to the pane's own host (``AgentPaneBridge``) instead, and that is the path a reader is on.
/// The page sends the same two ops either way — `callNative` falls back to the `agentSession`
/// handler when there is no page client — so this holds that path to the same promise: a chat the
/// reader left in the middle reopens there.
///
/// What the pane's own host was missing is the chat's *durable* place. A tab open at a clean quit
/// already came back where it was, through its wake state (`AgentPaneWakeState`, which goes
/// straight to `window.cmuxAcpmuxActions` and so needed neither host); the per-chat store these
/// ops write is what survives a crash, and what a different tab — or a tab closed and opened
/// again — reads.
@Suite(.serialized)
@MainActor
struct ChatScrollRestoreDefaultPathTests {
    /// What the pane's own host answers the page, as ``AgentPaneBridge`` routes it.
    static func call(_ method: String, _ params: [String: Any]) -> [String: Any] {
        AgentPaneScrollAnchors.reply(to: method, params: params)
    }

    static func value(_ reply: [String: Any]) -> Any? {
        #expect(reply["ok"] as? Bool == true, "the host refused the request: \(reply)")
        return reply["value"]
    }

    @Test func aChatReopensWhereItRestedWithThePageHostOff() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "anchors-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        // This run: the reader scrolls chat s-1 up and it rests on row user-42.
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory)
        _ = Self.value(Self.call("chat.scrollAnchor", ["sessionId": "s-1", "rowId": "user-42", "offset": 120.5]))

        // A fresh store — the next run after a crash, or another tab in this one — reads it back,
        // for that chat only.
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory)
        let place = Self.value(Self.call("chat.scrollAnchor.get", ["sessionId": "s-1"])) as? [String: Any]
        #expect(place?["rowId"] as? String == "user-42")
        #expect(place?["offset"] as? Double == 120.5)
        #expect(Self.value(Self.call("chat.scrollAnchor.get", ["sessionId": "s-2"])) is NSNull)

        // Back at the latest message: the place is forgotten, so the chat opens following the reply.
        _ = Self.value(Self.call("chat.scrollAnchor", ["sessionId": "s-1", "rowId": NSNull(), "offset": 0]))
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory)
        #expect(Self.value(Self.call("chat.scrollAnchor.get", ["sessionId": "s-1"])) is NSNull)
    }

    /// Both hosts read and write the one store, so a chat opened on either reopens where the other
    /// left it — a pane with `agent.pageHost` on beside one without, or the setting changed between
    /// two runs.
    @Test func thePageHostAndThePanesOwnHostShareTheOneStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "anchors-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory)

        // Written on the pane's own host, read on the page host.
        _ = Self.value(Self.call("chat.scrollAnchor", ["sessionId": "s-3", "rowId": "user-7", "offset": 8]))
        let provider = AgentPageProvider { _ in nil }
        let read = try await provider.call(
            AgentPageOps.namespace + "chat.scrollAnchor.get",
            params: .object(["sessionId": .string("s-3")]),
            context: PageCallContext(page: PageDescriptor.agent.id))
        #expect(read == .object(["rowId": .string("user-7"), "offset": .number(8)]))

        // And the other way: written on the page host, read on the pane's own.
        _ = try await provider.call(
            AgentPageOps.namespace + "chat.scrollAnchor",
            params: .object(["sessionId": .string("s-4"), "rowId": .string("user-9"), "offset": .number(3)]),
            context: PageCallContext(page: PageDescriptor.agent.id))
        let back = Self.value(Self.call("chat.scrollAnchor.get", ["sessionId": "s-4"])) as? [String: Any]
        #expect(back?["rowId"] as? String == "user-9")
    }

    @Test func aRequestWithoutAChatIsRefusedAndNothingIsKept() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "anchors-refuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory)
        #expect(Self.call("chat.scrollAnchor.get", [:])["ok"] as? Bool == false)
        #expect(Self.call("chat.scrollAnchor", ["sessionId": ""])["ok"] as? Bool == false)
        #expect(Self.call("chat.scrollAnchor.forget", ["sessionId": "s-5"])["ok"] as? Bool == false)
        // Refused, and nothing written under any of those chats.
        #expect(AgentPaneScrollAnchors.shared?.anchor(for: "s-5") == nil)
        #expect(AgentPaneScrollAnchors.shared?.anchor(for: "") == nil)
    }

    /// The routing, not only the answer. ``AgentPaneModel`` has no case for either op, so the pane's
    /// own host has to send them to this seam; take that branch out of ``AgentPaneBridge`` and a
    /// chat stops keeping its place again, which is the bug. A `WKScriptMessage` cannot be made in
    /// a test, so what is held is the predicate the bridge branches on and the model's lack of a
    /// route — the two halves that have to agree.
    @Test func thePanesOwnHostRoutesTheseOpsHereBecauseTheModelHasNoneForThem() {
        for method in ["chat.scrollAnchor", "chat.scrollAnchor.get"] {
            #expect(AgentPaneScrollAnchors.handles(method: method))
            let request = AgentPaneRequest(body: ["method": method, "params": ["sessionId": "s-1"]])
            guard case .unsupported(let named) = request else {
                Issue.record("\(method) now decodes to \(request), so the bridge's route to this seam is dead code")
                continue
            }
            #expect(named == method)
        }
        // Everything else stays the model's to answer or to refuse.
        #expect(AgentPaneScrollAnchors.handles(method: "chat.scrollAnchor.forget") == false)
        #expect(AgentPaneScrollAnchors.handles(method: "chat.tail") == false)
    }
}
