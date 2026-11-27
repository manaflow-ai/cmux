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

    @Test func unknownOperationsFailSoft() {
        #expect(CloudStartCore().callData("unknown_operation", Data("{}".utf8)) == nil)
    }
}
