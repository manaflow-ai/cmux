import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct CloudTurnOwnerClientTests {
    nonisolated final class TurnAPI: URLProtocol {
        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url else { return }
            if url.host == "original-generation.test", url.path.hasSuffix("/turns") {
                Issue.record("Capture must use the owner generation read before guest prepare, without re-reading")
            }
            if url.host == "registration-fails.test", !url.path.hasSuffix("/turns") {
                Issue.record("Failed local registration must not reserve a snapshot or mint a capability")
            }
            let ready = #"{"workspace":"ws_1","session":"session_1","turn":"turn_1","machineId":"vm_1","machineGeneration":7,"status":"ready"}"#
            let capability = #"{"capability":"trc_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","team":"team_1","user":"user_1","workspace":"ws_1","machine":"vm_1","session":"session_1","turn":"turn_1","generation":7,"expiresAt":9999999999999}"#
            let body: String
            if url.path.hasSuffix("/turns") {
                body = url.host == "wrong-machine.test" ? #"{"machineId":"vm_other","generation":7}"# : #"{"machineId":"vm_1","generation":7}"#
            } else if url.path.hasSuffix("/snapshot") { body = ready }
            else if url.path.hasSuffix("/capability") { body = capability }
            else { body = "{}" }
            let validAuth = request.value(forHTTPHeaderField: "Authorization") == "Bearer owner-only"
            let response = HTTPURLResponse(url: url, statusCode: validAuth ? 200 : 401, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func owner(_ host: String = "turn.test") -> CloudTurnOwnerClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TurnAPI.self]
        return CloudTurnOwnerClient(baseURL: URL(string: "https://\(host)")!, token: { "owner-only" }, transport: URLSession(configuration: configuration))
    }

    @Test func preparedTurnGetsOnlyScopedCapability() async throws {
        let data = try await owner().prepare(workspace: "ws_1", machine: "vm_1", session: "session_1", prompt: "prompt_1",
                                             prepared: Data(#"{"session":"session_1","turn":"turn_1"}"#.utf8))
        let result = String(decoding: data, as: UTF8.self)
        #expect(result.contains("trc_"))
        #expect(!result.contains("owner-only"))
    }

    @Test func captureKeepsTheGenerationReadBeforeGuestPrepare() async throws {
        let data = try await owner("original-generation.test").prepare(workspace: "ws_1", machine: "vm_1", session: "session_1", prompt: "prompt_1",
            prepared: Data(#"{"session":"session_1","turn":"turn_1"}"#.utf8),
            ownerState: Data(#"{"workspace":"ws_1","machine":"vm_1","generation":7}"#.utf8))
        #expect(String(decoding: data, as: UTF8.self).contains("trc_"))
    }

    @Test func differentWorkspaceMachineIsRefused() async {
        await #expect(throws: CloudTurnOwnerClient.Failure.self) {
            try await owner("wrong-machine.test").prepare(workspace: "ws_1", machine: "vm_1", session: "session_1", prompt: "prompt_1",
                                                        prepared: Data(#"{"session":"session_1","turn":"turn_1"}"#.utf8))
        }
    }

    @Test func failedBindingWriteDoesNotReserveAnUndeliveredTurn() async {
        await #expect(throws: CancellationError.self) {
            try await owner("registration-fails.test").prepare(workspace: "ws_1", machine: "vm_1", session: "session_1", prompt: "prompt_1",
                prepared: Data(#"{"session":"session_1","turn":"turn_1"}"#.utf8), verified: { throw CancellationError() })
        }
    }

    @Test func guestCannotChooseAnotherSessionOrPath() async {
        for prepared in [#"{"session":"other","turn":"turn_1"}"#, #"{"session":"session_1","turn":"../rewind"}"#] {
            await #expect(throws: CloudTurnOwnerClient.Failure.self) {
                try await owner().prepare(workspace: "ws_1", machine: "vm_1", session: "session_1", prompt: "prompt_1", prepared: Data(prepared.utf8))
            }
        }
    }
}
