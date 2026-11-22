import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The relay's allowlist (AcpmuxPaneMethods): default deny, the first frame is `initialize` and the
/// only one that gets the LocalApp token.
@Suite struct AcpmuxPaneMethodsTests {
    private func frame(_ method: String, id: Int? = 1, params: String = "{}") -> String {
        let idPart = id.map { #","id":\#($0)"# } ?? ""
        return #"{"jsonrpc":"2.0""# + idPart + #","method":"\#(method)","params":\#(params)}"#
    }

    @Test func theFirstFrameMustBeInitializeAndGetsTheToken() throws {
        guard case .send(let text) = AcpmuxPaneMethods.decide(frame("initialize"), isFirst: true, localAppToken: "abc") else {
            Issue.record("initialize refused"); return
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let acpmux = ((object["params"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        #expect(acpmux?["localAppToken"] as? String == "abc")
        #expect(AcpmuxPaneMethods.decide(frame("session/new"), isFirst: true, localAppToken: "abc")
            == .refuse(.firstFrameNotInitialize, method: "session/new", requestID: "1"))
        #expect(AcpmuxPaneMethods.decide(frame("initialize", id: nil), isFirst: true, localAppToken: "abc")
            == .refuse(.firstFrameNotInitialize, method: "initialize", requestID: nil))
    }

    @Test func withoutATokenTheFirstFrameIsSentAsWritten() {
        #expect(AcpmuxPaneMethods.decide(frame("initialize"), isFirst: true, localAppToken: nil) == .send(frame("initialize")))
    }

    @Test func aLaterInitializeAndUnlistedMethodsAreRefused() {
        for method in ["initialize", "_acpmux/peer_add", "_acpmux/preset_set", "git.diff", "file.search", "session/load"] {
            #expect(AcpmuxPaneMethods.decide(frame(method, id: 7), isFirst: false, localAppToken: nil)
                == .refuse(.methodRefused, method: method, requestID: "7"), "\(method)")
        }
        // A listed request sent as a notification, a listed notification sent as a request.
        #expect(AcpmuxPaneMethods.decide(frame("session/new", id: nil), isFirst: false, localAppToken: nil)
            == .refuse(.methodRefused, method: "session/new", requestID: nil))
        #expect(AcpmuxPaneMethods.decide(frame("session/cancel", id: 2), isFirst: false, localAppToken: nil)
            == .refuse(.methodRefused, method: "session/cancel", requestID: "2"))
        // A response (the pane sends none) and junk.
        #expect(AcpmuxPaneMethods.decide(#"{"jsonrpc":"2.0","id":3,"result":{}}"#, isFirst: false, localAppToken: nil)
            == .refuse(.methodRefused, method: nil, requestID: nil))
        #expect(AcpmuxPaneMethods.decide("not json", isFirst: false, localAppToken: nil) == .refuse(.invalidFrame, method: nil, requestID: nil))
    }

    @Test func everyListedMethodPassesAndCarriesNoToken() {
        for method in AcpmuxPaneMethods.requests {
            #expect(AcpmuxPaneMethods.decide(frame(method), isFirst: false, localAppToken: "abc") == .send(frame(method)), "\(method)")
        }
        #expect(AcpmuxPaneMethods.decide(frame("session/cancel", id: nil), isFirst: false, localAppToken: "abc")
            == .send(frame("session/cancel", id: nil)))
    }

    @Test func aRefusedRequestIsAnsweredWithAnErrorFrame() throws {
        let text = AcpmuxPaneMethods.refusal(requestID: #""r-1""#, error: .methodRefused, method: "_acpmux/peer_add")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "r-1")
        let data = (object["error"] as? [String: Any])?["data"] as? [String: Any]
        #expect(data?["code"] as? String == "transport.method_refused")
        #expect(data?["method"] as? String == "_acpmux/peer_add")
    }
}
