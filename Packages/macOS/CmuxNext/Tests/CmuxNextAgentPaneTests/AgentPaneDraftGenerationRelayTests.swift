import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Draft generation is a native ordering token. The page sends it with every durable draft write;
/// the host must forward that field while continuing to reject every unrelated parameter.
@Suite
struct AgentPaneDraftGenerationRelayTests {
    private static func frame(_ params: String) -> String {
        #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/draft_set","params":\#(params)}"#
    }

    @Test func aGenerationBearingDraftWritePassesTheNativeParamsRule() throws {
        let text = Self.frame(#"{"sessionId":"s-1","text":"new text","generation":5}"#)
        guard case .send = AcpmuxPaneMethods.decide(text, isFirst: false, localAppToken: nil) else {
            Issue.record("generation-bearing draft_set was refused by the native relay")
            return
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(!AcpmuxPaneMethods.breaksParamsRule(object, modeFields: []))
    }

    @Test(arguments: [
        #"{"sessionId":"s-1","text":"text","generation":5,"unexpected":true}"#,
        #"{"sessionId":"s-1","text":"text","revision":5}"#,
        #"{"sessionId":"s-1","text":"text","_meta":{"acpmux":{}}}"#,
    ])
    func unknownDraftWriteFieldsRemainRefused(_ params: String) throws {
        let text = Self.frame(params)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(AcpmuxPaneMethods.breaksParamsRule(object, modeFields: []), params)
        guard case .intentInvalid = AcpmuxPaneMethods.decide(text, isFirst: false, localAppToken: nil) else {
            Issue.record("unknown draft_set field escaped the native relay: \(params)")
            return
        }
    }
}
