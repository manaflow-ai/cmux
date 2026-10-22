import CmuxNextActions
import Foundation
import Testing

/// Lawrence 2026-10-22, "none of these worked": the links a Chief's reply carried. A workspace key
/// (`cmux://workspace/<uuid>`) and a subagent's chat link both parse, so `link.open` can find the
/// workspace in any session and the chat's tab.
struct DeepLinkChiefReplyTests {
    private func parse(_ text: String) -> DeepLink? { DeepLink.parse(URL(string: text)!, scheme: "cmux") }

    @Test(arguments: ["f8d01127-5c4a-45d5-8568-50a56041a6b6", "6885841b-99b4-4755-a336-2151a8f80ff5",
                      "1b9a583f-df9f-4ee8-9f88-1a0ae3deca2f"])
    func aWorkspaceKeyLinkNamesThatWorkspace(key: String) throws {
        let link = try #require(parse("cmux://workspace/\(key)"))
        #expect(link.target == .legacyWorkspace(try #require(UUID(uuidString: key)), fallback: nil))
    }

    @Test func aSubagentChatLinkNamesItsChiefSession() {
        let link = parse("cmux://chief/2e448bc2/session/01a161e0-f2df-7e21-83d4-fc229778848e")
        #expect(link?.target == .chiefSession(home: "2e448bc2", session: "01a161e0-f2df-7e21-83d4-fc229778848e"))
    }
}
