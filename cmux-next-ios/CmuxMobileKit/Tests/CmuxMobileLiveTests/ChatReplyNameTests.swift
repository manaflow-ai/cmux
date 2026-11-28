import CmuxMobileAgentChat
import Foundation
import Testing
@testable import CmuxMobileLive

/// Issue 51331: the chat's composer read "Reply to Take over https://github.com/manaflow-…", its
/// first prompt. acpmux titles a chat with its prompt until a real title comes (`titleSource`
/// `prompt`), so only a real title or a name someone gave the session names the chat.
@Suite struct ChatReplyNameTests {
    let prompt = "Take over https://github.com/manaflow-ai/cmux/pull/46908"

    func session(_ fields: [String: String]) throws -> AcpmuxSession {
        var object: [String: JSONValue] = ["sessionId": .string("s1"), "harness": .string("claude")]
        for (key, value) in fields { object[key] = .string(value) }
        return try #require(AcpmuxSession(.object(object)))
    }

    @Test func realTitlesNameTheChat() throws {
        for source in ["harness", "generated", "adopted"] {
            #expect(try session(["title": "46908: Attention ring timing", "titleSource": source]).chatName
                == "46908: Attention ring timing")
        }
    }

    @Test func promptTitleNeverNamesTheChat() throws {
        #expect(try session(["title": prompt, "titleSource": "prompt"]).chatName == nil)
        // An older daemon says no source: unknown, so not trusted.
        #expect(try session(["title": prompt]).chatName == nil)
        // A named chat keeps its prompt line as `title`; its name speaks for it.
        #expect(try session(["title": prompt, "titleSource": "named", "name": "46908: Attention ring timing"]).chatName
            == "46908: Attention ring timing")
    }

    @Test func muxNamesAreNotNames() throws {
        for name in ["claude", "claude-3", "claude-fork-2", "dispatch-019a3f2e", "optchat-sub-home-a12"] {
            #expect(try session(["name": name, "title": prompt, "titleSource": "prompt"]).chatName == nil, "\(name)")
        }
        #expect(try session(["name": "51331: Composer placeholder title"]).chatName == "51331: Composer placeholder title")
    }

    @Test func placeholderFollowsTheTitle() {
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: "46908: Attention ring timing") == "Reply to 46908: Attention ring timing")
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: nil) == "Reply…")
        #expect(AgentChatStore.replyPlaceholder(sessionTitle: "  ") == "Reply…")
    }
}
