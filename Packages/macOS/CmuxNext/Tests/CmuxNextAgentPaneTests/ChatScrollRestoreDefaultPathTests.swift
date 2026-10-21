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
/// reader left in the middle reopens there, after a relaunch too.
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
        // The default path: the setting that would move these ops to the page host is off.
        #expect(AgentPaneTunables.pageHost.value == false)

        // This run: the reader scrolls chat s-1 up and it rests on row user-42.
        AgentPaneScrollAnchors.shared = AgentPaneScrollAnchors(directory: directory)
        _ = Self.value(Self.call("chat.scrollAnchor", ["sessionId": "s-1", "rowId": "user-42", "offset": 120.5]))

        // The next run (a relaunch, or after kill -9) reads it back, for that chat only.
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
    }
}
