import CmuxNextCloud
import Foundation
import Testing

struct CloudStartCoreTests {
    @Test(arguments: [1, 4096, 1024 * 1024])
    func rawJSONPreservesLargeUnicodeReplies(startingCapacity: Int) throws {
        let account = String(repeating: "Renée 👋/", count: 1024)
        let request = try JSONSerialization.data(withJSONObject: ["account": [account, "team"]])
        let reply = try #require(CloudStartCore().callData("cloud_start_account_text", request, startingCapacity: startingCapacity))
        let object = try #require(JSONSerialization.jsonObject(with: reply) as? [String: String])
        #expect(object["text"] == account + "/team")
    }

    /// The app's hybrid begin matches `cmux chat --on cloud --attach`: an attached send's first turn runs here whole.
    @Test func anAttachedHybridSendBeginsWithTurnEnd() throws {
        #expect(CloudHybridGUIStart.beginArguments(session: "s", here: .init(turnEnd: false)) == ["cloud", "hybrid-begin", "s", "new"])
        #expect(CloudHybridGUIStart.beginArguments(session: "s", here: .init(turnEnd: true)) == ["cloud", "hybrid-begin", "s", "new", "--turn-end"])
        let send: [String: Any] = ["account": ["plan": "next_pro", "signedIn": true], "folder": true, "attachments": true, "attachOn": true,
                                   "catalog": ["defaultHarness": "claude", "harnesses": ["claude": [:] as [String: Any]]]]
        let reply = try #require(CloudStartCore().callData("cloud_hybrid_gui_start", JSONSerialization.data(withJSONObject: send)))
        let answer = try #require(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(answer["here"] as? Bool == true)
        #expect(answer["turnEnd"] as? Bool == true)
    }

    @Test func unknownOperationsFailSoft() {
        #expect(CloudStartCore().callData("unknown_operation", Data("{}".utf8)) == nil)
    }
}
