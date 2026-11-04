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

    /// A start that is not an agent chat's starts as the person's (no create card) when the person
    /// asked for it or lets agents start without asking; otherwise it asks (moved from the App, #35191).
    @Test func aStartIsThePersonsWhenTheyAskedOrLetAgentsStartWithoutAsking() {
        #expect(CloudStartCore().startsAsPerson(byPerson: true, delegated: false))
        #expect(CloudStartCore().startsAsPerson(byPerson: true, delegated: true))
        #expect(CloudStartCore().startsAsPerson(byPerson: false, delegated: true))
        #expect(!CloudStartCore().startsAsPerson(byPerson: false, delegated: false))
    }

    /// Only a personal send on a non-production sign-in copies through the content-addressed store (moved from the App, #34604).
    @Test func onlyAPersonalSendOnANonProductionSignInCopiesThroughTheStore() {
        #expect(CloudStartCore().copiesThroughStore(account: [], productionAuth: false))
        #expect(CloudStartCore().copiesThroughStore(account: ["user", nil], productionAuth: false))
        #expect(!CloudStartCore().copiesThroughStore(account: ["user", nil], productionAuth: true))
        #expect(!CloudStartCore().copiesThroughStore(account: ["user", "team"], productionAuth: false))
        #expect(!CloudStartCore().copiesThroughStore(account: ["user", "team"], productionAuth: true))
    }

    /// A plain name stays one bare shell word; anything else is single-quoted, its quotes escaped.
    @Test func aStartCommandWordIsOneShellWord() {
        #expect(CloudStartCore.shellQuoted("dev-1") == "dev-1")
        #expect(CloudStartCore.shellQuoted("") == "''")
        #expect(CloudStartCore.shellQuoted("my dev") == "'my dev'")
        #expect(CloudStartCore.shellQuoted("it's") == "'it'\\''s'")
        #expect(CloudStartCore.shellQuoted("a;rm -rf ~") == "'a;rm -rf ~'")
    }
}
