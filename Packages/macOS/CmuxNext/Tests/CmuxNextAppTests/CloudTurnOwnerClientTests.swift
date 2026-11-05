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
            var body: String
            if url.path.hasSuffix("/turns") {
                body = url.host == "wrong-machine.test" ? #"{"machineId":"vm_other","generation":7}"# : #"{"machineId":"vm_1","generation":7}"#
            } else if url.path.hasSuffix("/snapshot") { body = ready }
            else if url.path.hasSuffix("/capability") { body = capability }
            else { body = "{}" }
            if url.host == "prepare-auth.test" || url.host == "wrong-purpose.test" {
                if url.path.hasSuffix("/snapshot") { body = ready.replacingOccurrences(of: "turn_1", with: "prompt_1") }
                if url.path.hasSuffix("/capability") {
                    let payload = (Self.body(of: request).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
                    #expect(payload["expectedGeneration"] as? Int == 7)
                    #expect(payload["session"] as? String == "session_1")
                    #expect(url.path.contains("/turns/prompt_1/"))
                    let attempt = payload["attemptId"] as? String ?? ""
                    #expect(UUID(uuidString: attempt) != nil)
                    var minted = (try? JSONSerialization.jsonObject(with: Data(capability.utf8))) as? [String: Any] ?? [:]
                    minted["turn"] = "prompt_1"
                    minted["attemptId"] = attempt
                    minted["purpose"] = url.host == "wrong-purpose.test" ? "execute" : payload["purpose"]
                    body = String(decoding: (try? JSONSerialization.data(withJSONObject: minted)) ?? Data(), as: UTF8.self)
                }
            }
            let validAuth = request.value(forHTTPHeaderField: "Authorization") == "Bearer owner-only"
            let response = HTTPURLResponse(url: url, statusCode: validAuth ? 200 : 401, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        private static func body(of request: URLRequest) -> Data? {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
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

    @Test func preparationAndExecutionKeepOneTurnGenerationAndAttempt() async throws {
        let client = owner("prepare-auth.test")
        let state = try await client.authorizePreparation(workspace: "ws_1", machine: "vm_1", session: "session_1", prompt: "prompt_1")
        let scope = try #require(JSONSerialization.jsonObject(with: state) as? [String: Any])
        let authorization = try #require(scope["authorization"] as? [String: Any])
        #expect(authorization["purpose"] as? String == "prepare")
        #expect(authorization["turn"] as? String == "prompt_1")
        #expect(!String(decoding: state, as: UTF8.self).contains("owner-only"))
        let prepared = try JSONSerialization.data(withJSONObject: ["session":"session_1", "turn":"prompt_1",
            "generation":7, "attempt_id": try #require(authorization["attemptId"] as? String)])
        let capability = try await client.prepare(workspace: "ws_1", machine: "vm_1", session: "session_1", prompt: "prompt_1",
            prepared: prepared, ownerState: state)
        let execution = try #require(JSONSerialization.jsonObject(with: capability) as? [String: Any])
        #expect(execution["purpose"] as? String == "execute")
        #expect(execution["attemptId"] as? String == authorization["attemptId"] as? String)
        for prepared in [#"{"session":"session_1","turn":"another","generation":7}"#,
                         #"{"session":"session_1","turn":"prompt_1","generation":8}"#,
                         #"{"session":"session_1","turn":"prompt_1","generation":7,"attempt_id":"another"}"#] {
            await #expect(throws: CloudTurnOwnerClient.Failure.self) {
                try await client.prepare(workspace: "ws_1", machine: "vm_1", session: "session_1", prompt: "prompt_1",
                    prepared: Data(prepared.utf8), ownerState: state)
            }
        }
    }

    @Test func executionTokenCannotAuthorizePreparation() async {
        await #expect(throws: CloudTurnOwnerClient.Failure.self) {
            try await owner("wrong-purpose.test").authorizePreparation(workspace: "ws_1", machine: "vm_1", session: "session_1", prompt: "prompt_1")
        }
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
