import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The host's early `initialize` (AgentPaneTransport.open(_:earlyInitialize:)): its answer is kept
/// and the page's own `initialize` with the same params takes it, with no second round trip.
struct AcpmuxEarlyInitializeTests {
    static let params: [String: Any] = ["protocolVersion": 1, "clientInfo": ["name": "cmux"]]

    static func earlyRelay(_ ids: AcpmuxRequestIds) throws -> Int {
        let frame = try #require(AcpmuxRequestIds.earlyInitializeFrame(params: params))
        ids.expectEarlyInitialize(frame)
        return try #require(ids.begin(pageID: AcpmuxRequestIds.earlyInitializePageID, method: "initialize"))
    }

    static func pageInitialize(id: Int, params: [String: Any] = params) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "initialize", "params": params])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func answerBeforeThePageAsksIsKeptThenGivenToThePageID() throws {
        let ids = AcpmuxRequestIds()
        let relay = try Self.earlyRelay(ids)
        #expect(ids.earlyInitializeOutstanding)
        guard case .early(let object) = ids.toPage(#"{"jsonrpc":"2.0","id":\#(relay),"result":{"protocolVersion":1}}"#) else {
            Issue.record("the early answer went to the page")
            return
        }
        #expect((object["result"] as? [String: Any])?["protocolVersion"] as? Int == 1)
        guard case .answered(let text) = ids.adoptEarlyInitialize(try Self.pageInitialize(id: 3)) else {
            Issue.record("the page's initialize did not take the kept answer")
            return
        }
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(reply["id"] as? Int == 3)
        #expect((reply["result"] as? [String: Any])?["protocolVersion"] as? Int == 1)
        #expect(!ids.earlyInitializeOutstanding)
        // A second initialize is the page's own.
        #expect(ids.adoptEarlyInitialize(try Self.pageInitialize(id: 4)) == .none)
    }

    @Test func pageAskingFirstGetsTheAnswerUnderItsID() throws {
        let ids = AcpmuxRequestIds()
        let relay = try Self.earlyRelay(ids)
        #expect(ids.adoptEarlyInitialize(try Self.pageInitialize(id: 5)) == .waiting)
        guard case .page(let text, _, let method) = ids.toPage(#"{"jsonrpc":"2.0","id":\#(relay),"result":{}}"#) else {
            Issue.record("the answer did not go to the page")
            return
        }
        #expect(method == "initialize")
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(reply["id"] as? Int == 5)
    }

    @Test func otherParamsOrOtherMethodsGoToTheDaemon() throws {
        let ids = AcpmuxRequestIds()
        _ = try Self.earlyRelay(ids)
        #expect(ids.adoptEarlyInitialize(try Self.pageInitialize(id: 6, params: ["protocolVersion": 2])) == .none)
        #expect(ids.adoptEarlyInitialize(#"{"jsonrpc":"2.0","id":7,"method":"_acpmux/status"}"#) == .none)
        #expect(ids.earlyInitializeOutstanding)
    }

    @Test func noEarlyInitializeLeavesThePageInitializeAlone() throws {
        let ids = AcpmuxRequestIds()
        #expect(!ids.earlyInitializeOutstanding)
        #expect(ids.adoptEarlyInitialize(try Self.pageInitialize(id: 1)) == .none)
    }

    @Test func cancelledEarlyInitializeIsForgotten() throws {
        let ids = AcpmuxRequestIds()
        let relay = try Self.earlyRelay(ids)
        ids.cancel(relay)
        #expect(!ids.earlyInitializeOutstanding)
    }
}
