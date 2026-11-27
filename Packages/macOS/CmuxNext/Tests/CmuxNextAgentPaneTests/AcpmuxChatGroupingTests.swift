import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite struct AcpmuxChatGroupingTests {
    private func chat(harness: String = "claude-code", cwd: String? = nil, accounts: [String] = []) -> AcpmuxChat {
        AcpmuxChat(id: "chat", sessionID: "session", harness: harness, cwd: cwd,
                   updatedAt: Date(timeIntervalSince1970: 1), accounts: accounts)
    }

    @Test func harnessGroupingUsesHarnessId() {
        #expect(chat(harness: "codex").groupValue(.harness) == "codex")
    }

    @Test func folderGroupingUsesRawFolder() {
        #expect(chat(cwd: "/work/project").groupValue(.folder) == "/work/project")
        #expect(chat(cwd: "").groupValue(.folder) == "")
        #expect(chat().groupValue(.folder) == nil)
    }

    @Test func accountGroupingUsesFirstNonEmptyAccountInOrder() {
        #expect(chat(accounts: ["", "personal", "work"]).groupValue(.account) == "personal")
        #expect(chat(accounts: ["work", "personal"]).groupValue(.account) == "work")
    }

    @Test func accountGroupingHasNoValueWithoutAnAccount() {
        #expect(chat().groupValue(.account) == nil)
        #expect(chat(accounts: ["", ""]).groupValue(.account) == nil)
    }
}
