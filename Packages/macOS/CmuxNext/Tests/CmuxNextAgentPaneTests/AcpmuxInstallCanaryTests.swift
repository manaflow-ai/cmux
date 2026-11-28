import Foundation
import Testing
@testable import CmuxNextAgentPane

/// NIGHTLY's install check canary (``AcpmuxInstallCanary``): the hello it sends is the page's own
/// `initialize`, it passes the relay's real first-frame check, a frame the relay would refuse comes
/// back refused with the reason a chat sees (cmux#46563's `transport.intent_invalid`), and the
/// daemon's answer maps to passed, refused or inconclusive.
@Suite
struct AcpmuxInstallCanaryTests {
    @Test func theHelloIsThePagesInitialize() throws {
        let contract = try AcpmuxPaneInitializeParamsContractTests.contract()
        let canary = try JSONSerialization.data(withJSONObject: AcpmuxInstallCanary.pageInitializeParams, options: .sortedKeys)
        let page = try JSONSerialization.data(withJSONObject: contract, options: .sortedKeys)
        #expect(canary == page)
    }

    @Test func theRelayTakesTheHello() {
        #expect(AcpmuxInstallCanary.relayRefusal() == nil)
    }

    /// The incident's shape: since cmux#49717 a field the relay does not know goes without it, so the
    /// very first frame still opens the chat; a forged shape on it is still refused with the reason a
    /// chat sees.
    @Test func aFieldTheRelayDoesNotAcceptIsRefused() throws {
        let snapshot = AgentPaneTransport.Snapshot(isFirst: true, localAppToken: nil, socketPath: nil, modeFields: nil,
                                                   sessions: AcpmuxPaneSessions(), options: AcpmuxPermissionOptions())
        let newer = #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"newField":true,"_meta":{"acpmux":{"peerRowBatches":true}},"clientCapabilities":{},"clientInfo":{"name":"cmux-react-agent-pane","version":"1"},"protocolVersion":1}}"#
        guard case .frame(_, let box) = AgentPaneTransport.checkOne(newer, snapshot) else {
            Issue.record("the relay refused a first frame for a field it does not know")
            return
        }
        let encoded = try #require(box.encoded(id: 1))
        let object = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["newField"] == nil, "the unknown field reached acpmux: \(encoded)")
        #expect(params["clientInfo"] != nil)

        let forged = #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"_meta":{"acpmux":"peerRowBatches"},"clientCapabilities":{},"clientInfo":{"name":"cmux-react-agent-pane","version":"1"},"protocolVersion":1}}"#
        guard case .refuse(.refuse(let error, _, _, _), _) = AgentPaneTransport.checkOne(forged, snapshot) else {
            Issue.record("the relay took a first frame whose _meta.acpmux is not an object")
            return
        }
        #expect(error.rawValue == "transport.intent_invalid")
    }

    @Test func aResultPasses() async throws {
        let stream = Stream([#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"# + "\n"])
        #expect(try await AcpmuxInstallCanary.hello(on: stream) == .passed)
        let sent = await stream.sent
        #expect(sent == [Data((AcpmuxInstallCanary.pageInitialize + "\n").utf8)])
    }

    @Test func anErrorIsARefusal() async throws {
        let stream = Stream([#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad params","data":{"reason":"transport.intent_invalid"}}}"# + "\n"])
        #expect(try await AcpmuxInstallCanary.hello(on: stream) == .refused("transport.intent_invalid: bad params", retryable: false))
    }

    /// A busy daemon's refusal carries its `data.retryable`, so the decision (Rust) takes it as
    /// inconclusive instead of a refused build.
    @Test func aRetryableErrorSaysSo() async throws {
        let stream = Stream([#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"connection request limit reached","data":{"reason":"connection.busy","retryable":true}}}"# + "\n"])
        #expect(try await AcpmuxInstallCanary.hello(on: stream) == .refused("connection.busy: connection request limit reached", retryable: true))
    }

    @Test func aReplySplitOverChunksAfterANotificationPasses() async throws {
        let stream = Stream([#"{"jsonrpc":"2.0","method":"note"}"# + "\n" + #"{"jsonrpc":"2.0","id":1,"#, #""result":{}}"# + "\n"])
        #expect(try await AcpmuxInstallCanary.hello(on: stream) == .passed)
    }

    @Test func aCloseBeforeTheReplyIsInconclusive() async throws {
        #expect(try await AcpmuxInstallCanary.hello(on: Stream([])) == .inconclusive("closed before the reply"))
    }

    private actor Stream: AcpmuxRPCTransport {
        private var chunks: [Data]
        private(set) var sent: [Data] = []
        init(_ chunks: [String]) { self.chunks = chunks.map { Data($0.utf8) } }
        func start() async throws {}
        func send(_ data: Data) async throws { sent.append(data) }
        func receive() async throws -> Data? { chunks.isEmpty ? nil : chunks.removeFirst() }
    }
}
