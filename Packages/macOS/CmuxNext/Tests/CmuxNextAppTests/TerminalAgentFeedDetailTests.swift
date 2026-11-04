@testable import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// A terminal agent's Feed card says what the agent said, as a GUI chat's does. The daemon keeps
/// the agent's answer, question or approval command in memory and sends it as a local feed item's
/// `detail` (never in the durable row); the handoff puts it in the Feed as the body. Before, a
/// Claude Code terminal's card read "Claude finished" and nothing more: only the live event had
/// the answer, and the item the Mac handed to the Feed had an empty body.
@Suite
struct TerminalAgentFeedDetailTests {
    static let answer = "The build is green.\n\n- 3 tests fixed\n- `swiftlint` clean"

    @Test func aFeedLocalItemDecodesItsAgentsDetail() throws {
        func item(_ extra: String) throws -> FeedLocalItem {
            let json = #"{"id":"fi_aaaaaaaaaaaaaaaaaaaa","dedupe_key":"notify:s:n1","title":"Claude finished","body":"","#
                + #""level":"info","source":"agent","context":{"terminal":"term_1"},"created_at_ms":1,"#
                + #""updated_at_ms":1,"state":"open","count":1"# + extra + "}"
            return try JSONDecoder().decode(FeedLocalItem.self, from: Data(json.utf8))
        }
        let encoded = String(decoding: try JSONEncoder().encode(Self.answer), as: UTF8.self)
        #expect(try item(#","detail":"# + encoded).detail == Self.answer)
        #expect(try item("").detail == nil, "a daemon without details still decodes")
    }

    @Test func theHandoffSendsTheAgentsAnswerAsTheFeedBody() {
        let policy = FeedHandoffPolicy(preferences: NotificationPreferences(), mutedWorkspaces: [])
        let item = FeedLocalItem(id: "fi_aaaaaaaaaaaaaaaaaaaa", dedupeKey: "k", title: "Claude finished", body: "",
                                 source: "agent", context: .init(terminal: "term_1"), createdAtMs: 1,
                                 detail: Self.answer)
        let content = policy.content(for: item)
        #expect(content?.title == "Claude finished")
        #expect(content?.body == Self.answer, "the Feed card shows the answer, not an empty body")
        let body = FeedHandoffDriver.adoptBody(item, install: "inst_1", content: content ?? ("", ""))
        let cloud = (body["params"] as? [String: Any])?["item"] as? [String: Any]
        #expect(cloud?["body"] as? String == Self.answer)
    }

    @Test func anItemWithoutDetailKeepsItsBody() {
        let policy = FeedHandoffPolicy(preferences: NotificationPreferences(), mutedWorkspaces: [])
        let item = FeedLocalItem(id: "fi_bbbbbbbbbbbbbbbbbbbb", dedupeKey: "k", title: "Claude needs approval",
                                 body: "Bash", source: "agent", context: .init(terminal: "term_1"), createdAtMs: 1)
        #expect(policy.content(for: item)?.body == "Bash")
    }
}
