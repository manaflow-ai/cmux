import CmuxMobileAgentChat
import Foundation
import Testing
@testable import CmuxMobileLive

/// The acpmux side of the chat polish rows (cmux#25834): the records bookmarks read, the
/// identity the Copy rows and Session Info read, the permission state and the kinds a chat
/// reads.
@Suite struct ChatPolishParityLiveTests {
    let records = AcpmuxRecords(sessionID: "s1")

    func json(_ string: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }

    @Test func aPromptNamesItsRecordForItsBookmark() throws {
        let prompt = try json(#"{"seq":12,"dir":"mux","kind":"user_message","msg":{"turnId":"t3","promptId":"p","text":"hi"}}"#)
        #expect(records.map(prompt).last == .promptSeq(turnId: "t3", seq: 12))
        // A message steered into a running turn is no prompt of its own.
        let steer = try json(#"{"seq":14,"dir":"mux","kind":"user_message","msg":{"turnId":"t3","promptId":"q","text":"also","steer":true}}"#)
        #expect(!records.map(steer).contains(.promptSeq(turnId: "t3", seq: 14)))
    }

    @Test @MainActor func theBookmarksRecordCarriesEveryMark() throws {
        let marks = try json(#"{"seq":30,"dir":"mux","kind":"bookmarks","msg":{"bookmarks":[12,29]}}"#)
        #expect(records.map(marks) == [.bookmarks([12, 29])])
        #expect(AcpmuxSessionSource.marks(try json(#"{"sessionId":"s1","bookmarks":[4,9]}"#)) == [4, 9])
        // A chat hears a mark made on the Mac: its reads ask for the record.
        #expect(AcpmuxSessionSource.chatKinds.arrayValue?.contains(.string("bookmarks")) == true)
    }

    @Test func detailsReadTheNameIdsFolderAndHost() throws {
        let info = try json(#"""
        {"sessionId":"s-1","name":"fix tests","agentSessionId":"claude-uuid","cwd":"/Users/me/p","harness":"claude"}
        """#)
        let details = AcpmuxSessionSource.sessionDetails(info, sessionID: "s-1", macName: "Studio", fallbackHarness: "Claude")
        #expect(AcpmuxSessionSource.sessionDetails(try json(#"{"sessionId":"s-3","machine":"Mac Studio 2"}"#), sessionID: "s-3", macName: "Studio", fallbackHarness: "Claude").host == "Mac Studio 2")
        #expect(details.name == "fix tests")
        #expect(details.harnessSessionID == "claude-uuid")
        #expect(details.cwd == "/Users/me/p")
        #expect(details.host == "Studio")
        #expect(details.detailsText == "Agent name: fix tests\nAgent identifier: s-1\nHarness session ID: claude-uuid\nCWD: /Users/me/p\nHost: Studio")
        let peer = try json(#"{"sessionId":"s-2","peer":"build-box","agent_session_id":"x"}"#)
        let remote = AcpmuxSessionSource.sessionDetails(peer, sessionID: "s-2", macName: "Studio", fallbackHarness: "Codex")
        #expect(remote.host == "build-box")
        #expect(remote.harnessSessionID == "x")
        #expect(remote.detailsText == "Agent identifier: s-2\nHarness session ID: x\nHost: build-box")
    }

    @Test func permissionsReadTheChatAllowanceAndOpenGroups() throws {
        let reply = try json(#"""
        {"groups":[{"groupId":"g1","state":"pending"},{"groupId":"g2","state":"resolved"}],"chatAllowance":{"active":true}}
        """#)
        #expect(AcpmuxSessionSource.permissions(reply) == AgentChatPermissions(allowedForChat: true, openGroups: 1))
        #expect(AcpmuxSessionSource.permissions(try json(#"{"groups":[]}"#)) == AgentChatPermissions(allowedForChat: false, openGroups: 0))
    }
}
