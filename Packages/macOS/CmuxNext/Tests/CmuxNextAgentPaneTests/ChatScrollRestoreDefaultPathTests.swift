import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cx-6bgzj on the page host, the one host a chat opens on (p13-webui-073 deleted the pane's own):
/// a chat the reader left in the middle reopens there, from the per-chat store the two ops write.
/// That store is what survives a crash, and what a different tab, or a tab closed and opened
/// again, reads. `ChatScrollRestoreTests` drives the provider's async call; these drive the op's
/// answer with the page's own params.
@Suite(.serialized)
@MainActor
struct ChatScrollRestoreDefaultPathTests {
    /// What the page host answers the page (`AgentPageProvider.scrollAnchor`): `ok` and the value,
    /// or `ok: false` for a request it refuses or an op that is not this store's.
    static func call(_ method: String, _ params: [String: Any]) -> [String: Any] {
        guard AgentPaneScrollAnchors.handles(method: method), let json = JSONValue(foundation: params) else { return ["ok": false] }
        guard let value = try? AgentPageProvider.scrollAnchor(method, params: json, op: AgentPageOps.namespace + method)
        else { return ["ok": false] }
        return ["ok": true, "value": value.foundationObject]
    }

    static func value(_ reply: [String: Any]) -> Any? {
        #expect(reply["ok"] as? Bool == true, "the host refused the request: \(reply)")
        return reply["value"]
    }

    @Test func aChatReopensWhereItRested() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "anchors-page-host-\(UUID().uuidString)")
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

    /// Two pages of the one host share the one store: written through the provider's call, read
    /// through the op's answer, and the other way.
    @Test func everyPageSharesTheOneStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "anchors-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            AgentPaneScrollAnchors.shared = nil
            try? FileManager.default.removeItem(at: directory)
        }
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory)

        _ = Self.value(Self.call("chat.scrollAnchor", ["sessionId": "s-3", "rowId": "user-7", "offset": 8]))
        let provider = AgentPageProvider { _ in nil }
        let read = try await provider.call(
            AgentPageOps.namespace + "chat.scrollAnchor.get",
            params: .object(["sessionId": .string("s-3")]),
            context: PageCallContext(page: PageDescriptor.agent.id))
        #expect(read == .object(["rowId": .string("user-7"), "offset": .number(8)]))

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

    /// ``AgentPaneModel`` has no case for either op, so the page host answers them here
    /// (``AgentPageProvider``, before it decodes a request for the model).
    @Test func theModelHasNoRouteOfItsOwnForTheseOps() {
        for method in ["chat.scrollAnchor", "chat.scrollAnchor.get"] {
            #expect(AgentPaneScrollAnchors.handles(method: method))
            let request = AgentPaneRequest(body: ["method": method, "params": ["sessionId": "s-6"]] as [String: Any])
            guard case .unsupported(let named) = request else {
                Issue.record("\(method) now decodes to \(request), so the page host should stop intercepting it")
                continue
            }
            #expect(named == method)
        }
        #expect(!AgentPaneScrollAnchors.handles(method: "chat.unsentDraft"))
        #expect(!AgentPaneScrollAnchors.handles(method: "chat.scrollAnchor.forget"))
    }
}
