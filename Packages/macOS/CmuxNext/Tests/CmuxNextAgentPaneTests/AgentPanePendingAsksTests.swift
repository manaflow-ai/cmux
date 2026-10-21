import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The Needs you list reads each chat's open permission requests through the page's own op
/// (`cmux.agent.chat.asks.pending`), never the relay: the relay refuses `_acpmux/info`, so a read
/// sent there never lands and answered asks stay listed (PR #22646 review). The op must stay on
/// the page's op list, reach the host's reader with the chat's id, and hand back only the fields
/// the pane's watch already carries.
@Suite(.serialized)
@MainActor
struct AgentPanePendingAsksTests {
    /// The sessions the reader was asked for.
    @MainActor final class Asked {
        var sessions: [String] = []
    }

    static let context = PageCallContext(page: PageDescriptor.agent.id)

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// The op from a pane wired as ``AgentPaneView`` wires it, on `model`'s chat (a chat on this Mac
    /// by default).
    static func call(_ params: [String: JSONValue], model: AgentPaneModel? = nil) async throws -> JSONValue {
        let model = model ?? AgentPaneModel(host: NoHost())
        let provider = AgentPageProvider { _ in nil }
        provider.servesLocalChat = { model.readsThisMacsAcpmux }
        return try await provider.call(AgentPageOps.namespace + "chat.asks.pending", params: .object(params), context: context)
    }

    @Test func thePageReadsAChatsOpenAsksThroughTheHostNotTheRelay() async throws {
        #expect(AgentPageOps.all.contains("cmux.agent.chat.asks.pending"))
        // The relay refuses this read: that is why the host serves it.
        #expect(!AcpmuxPaneMethods.requests.contains("_acpmux/info"))

        let asked = Asked()
        AgentPanePendingAsks.shared = AgentPanePendingAsks { session in
            asked.sessions.append(session)
            let request: [String: Any] = ["toolCall": ["title": "Run npm test"]]
            let entry: [String: Any] = ["permissionId": "p1", "request": request, "turnId": "t1", "groupId": NSNull(),
                                        "answeredBy": "x", "secret": "kept on the host"]
            return ["sessionId": session, "pending": [entry]]
        }
        defer { AgentPanePendingAsks.shared = nil }

        let reply = try await Self.call(["sessionId": .string("s-1")])
        #expect(asked.sessions == ["s-1"])
        guard case .object(let body) = reply, case .array(let entries)? = body["pending"],
              case .object(let entry)? = entries.first else {
            Issue.record("expected {pending: [entry]}, got \(reply)")
            return
        }
        #expect(Set(entry.keys) == ["permissionId", "request", "turnId", "groupId"])
        #expect(entry["permissionId"] == .string("p1"))
        #expect(entry["turnId"] == .string("t1"))
    }

    @Test func aChatThatCannotBeReadAnswersNull() async throws {
        AgentPanePendingAsks.shared = AgentPanePendingAsks { _ in nil }
        defer { AgentPanePendingAsks.shared = nil }
        #expect(try await Self.call(["sessionId": .string("s-remote")]) == .null)
        AgentPanePendingAsks.shared = nil
        #expect(try await Self.call(["sessionId": .string("s-1")]) == .null)
    }

    /// A pane on another machine's chat (``RemoteAcpmuxWire``) reaches only that one session; this
    /// read goes to this Mac's acpmux, so it never runs there, whatever chat it names (PR #22646 review).
    @Test func aPaneOnAnotherMachinesChatGetsNullAndNeverReadsThisMac() async throws {
        let asked = Asked()
        AgentPanePendingAsks.shared = AgentPanePendingAsks { session in
            asked.sessions.append(session)
            return ["sessionId": session, "pending": [["permissionId": "p1"]]]
        }
        defer { AgentPanePendingAsks.shared = nil }

        let remote = AgentPaneModel(host: NoHost())
        remote.remoteChat = true
        #expect(try await Self.call(["sessionId": .string("a-chat-on-this-mac")], model: remote) == .null)
        // A provider no pane has wired fails closed too.
        let unwired = AgentPageProvider { _ in nil }
        let reply = try await unwired.call(AgentPageOps.namespace + "chat.asks.pending",
                                           params: .object(["sessionId": .string("a-chat-on-this-mac")]), context: Self.context)
        #expect(reply == .null)
        #expect(asked.sessions.isEmpty)

        // The same read from a pane on this Mac's chat goes through.
        #expect(try await Self.call(["sessionId": .string("a-chat-on-this-mac")]) != .null)
        #expect(asked.sessions == ["a-chat-on-this-mac"])
    }

    @Test func paramsOtherThanOneSessionIdAreRefused() async throws {
        AgentPanePendingAsks.shared = AgentPanePendingAsks { _ in [:] }
        defer { AgentPanePendingAsks.shared = nil }
        await #expect(throws: PageError.self) { _ = try await Self.call([:]) }
        await #expect(throws: PageError.self) { _ = try await Self.call(["sessionId": .string("")]) }
        await #expect(throws: PageError.self) {
            _ = try await Self.call(["sessionId": .string("s-1"), "method": .string("_acpmux/kill")])
        }
    }
}
