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

    static func call(_ params: [String: JSONValue]) async throws -> JSONValue {
        let provider = AgentPageProvider { _ in nil }
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
