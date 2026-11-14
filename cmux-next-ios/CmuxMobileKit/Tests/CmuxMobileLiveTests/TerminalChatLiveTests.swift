import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// Toggle Terminal and Chat at the backend's boundary: what the phone reads from acpmux's chat list
/// to pair a chat with a terminal, and the View Only chat request it sends, the Mac's own adopt.
@Suite struct TerminalChatLiveTests {
    func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func aChatNamesTheHarnessSessionItShowsAndWhetherItOnlyWatches() throws {
        let watch = try #require(AcpmuxSession(try json(
            #"{"sessionId":"a-1","harness":"claude","cwd":"/p","status":"idle","agentSessionId":"h-1","watching":"claude"}"#)))
        #expect(watch.agentSessionID == "h-1" && watch.watching)
        let listing = try #require(LiveWorkspaceCreationBackend.terminalChatListing(watch))
        #expect(listing == TerminalChatListing(sessionID: "a-1", harness: "claude", agentSessionID: "h-1", watching: true, status: "idle"))

        let runs = try #require(AcpmuxSession(try json(
            #"{"sessionId":"a-2","harness":"codex","status":"running","agentSessionId":"","watching":null}"#)))
        #expect(runs.agentSessionID == nil && !runs.watching)
        // A peer's chat runs on another machine: it pairs with no terminal of this Mac.
        let peer = try #require(AcpmuxSession(try json(
            #"{"sessionId":"a-3","harness":"claude","peer":"studio","agentSessionId":"h-1","watching":"claude"}"#)))
        #expect(LiveWorkspaceCreationBackend.terminalChatListing(peer) == nil)
    }

    @Test func theViewOnlyChatRequestIsTheMacsAdopt() throws {
        let params = LiveWorkspaceCreationBackend.terminalChatParams(harness: "claude", session: "h-1", cwd: "/Users/me/p")
        #expect(params["cwd"]?.stringValue == "/Users/me/p")
        #expect(params["mcpServers"]?.arrayValue?.isEmpty == true)
        let acpmux = try #require(params["_meta"]?["acpmux"])
        #expect(acpmux["policy"]?.stringValue == "ask")
        #expect(acpmux["adopt"] == .object(["harness": .string("claude"), "agentSessionId": .string("h-1"), "watch": .bool(true)]))
        // No folder known (or not absolute): acpmux reads it from the harness's own record.
        #expect(LiveWorkspaceCreationBackend.terminalChatParams(harness: "codex", session: "h-2", cwd: nil)["cwd"] == nil)
        #expect(LiveWorkspaceCreationBackend.terminalChatParams(harness: "codex", session: "h-2", cwd: "~/p")["cwd"] == nil)
    }
}
