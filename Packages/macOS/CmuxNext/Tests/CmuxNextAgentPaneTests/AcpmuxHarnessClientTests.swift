import Foundation
import Testing
@testable import CmuxNextAgentPane

/// BRING-YOUR-OWN-HARNESS: the harness operations keep the daemon's reason id (`data.reason`), so
/// Settings can say why, and an older daemon's "no such method" becomes the CLI fallback.
@Suite struct AcpmuxHarnessClientTests {
    @Test func aRefusalKeepsTheDaemonsReasonAndText() throws {
        let line = Data(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"acme already has a profile","data":{"reason":"harness.exists"}}}"#.utf8)
        #expect(throws: AcpmuxRPCError(code: -32602, name: "harness.exists", message: "acme already has a profile")) {
            try AcpmuxStatusClient.detailedReply(to: 2, in: line)
        }
    }

    @Test func anOlderDaemonAnswersMethodMissing() {
        let error = AcpmuxRPCError(["code": -32601, "message": "method not found"])
        #expect(error.isMethodMissing)
        #expect(error.name == nil)
    }

    @Test func otherRepliesAndTheResultPassThrough() throws {
        #expect(try AcpmuxStatusClient.detailedReply(to: 2, in: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) == nil)
        let result = try #require(try AcpmuxStatusClient.detailedReply(to: 2, in: Data(#"{"jsonrpc":"2.0","id":2,"result":{"id":"acme"}}"#.utf8)))
        #expect(result["id"] as? String == "acme")
    }

    @Test func onlyTheHarnessChangeNotificationWakesSettings() {
        #expect(AcpmuxEnvironment.isHarnessChange(Data(#"{"jsonrpc":"2.0","method":"_acpmux/harnesses_changed","params":{}}"#.utf8)))
        #expect(!AcpmuxEnvironment.isHarnessChange(Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{}}"#.utf8)))
        #expect(!AcpmuxEnvironment.isHarnessChange(Data("not json".utf8)))
    }
}
