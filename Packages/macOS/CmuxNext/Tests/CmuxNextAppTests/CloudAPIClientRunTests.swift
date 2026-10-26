import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// `cmux run --sandboxed` (hq#3367) goes through these: the create sends the
/// Run API's required Idempotency-Key, and every call answers the raw JSON.
@Suite(.serialized)
struct CloudAPIClientRunTests {
    nonisolated final class RunAPI: URLProtocol {
        nonisolated(unsafe) static var seen: [(method: String, path: String, key: String?)] = []

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            let path = url.path + (url.query.map { "?" + $0 } ?? "")
            Self.seen.append((request.httpMethod ?? "", path, request.value(forHTTPHeaderField: "Idempotency-Key")))
            let body = path.hasSuffix("/wait?timeoutMs=10000")
                ? #"{"run":{"id":"run-1","status":"succeeded"},"receipt":{"schema":"cmux.run.receipt/v1"}}"#
                : #"{"id":"run-1","status":"queued"}"#
            guard let response = HTTPURLResponse(url: url, statusCode: path == "/api/runs" ? 202 : 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func api() -> CloudAPIClient {
        let configuration = CloudConfiguration.resolve(
            bundleID: nil,
            bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
            process: [:],
            isDebugBuild: true
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RunAPI.self]
        return CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { "team-1" },
                              session: URLSession(configuration: sessionConfiguration))
    }

    @Test func createSendsTheKeyAndWaitIsCappedAtTheServerBound() async throws {
        RunAPI.seen = []
        let api = api()
        let created = try JSONSerialization.jsonObject(with: try await api.createSandboxRun(task: "hi", agent: "claude",
                                                                                            idempotencyKey: "key-1")) as? [String: Any]
        #expect(created?["id"] as? String == "run-1")
        let waited = try JSONSerialization.jsonObject(with: try await api.waitRun("run-1", timeoutMs: 60_000)) as? [String: Any]
        #expect((waited?["receipt"] as? [String: Any])?["schema"] as? String == "cmux.run.receipt/v1")
        #expect(RunAPI.seen.map(\.method) == ["POST", "GET"])
        #expect(RunAPI.seen.map(\.path) == ["/api/runs", "/api/runs/run-1/wait?timeoutMs=10000"])
        #expect(RunAPI.seen.first?.key == "key-1")
    }
}

/// A new sandboxed run belongs to the Cloud feature: an administrator who turns Cloud off turns
/// it off. Waiting on or cancelling a run that exists stays open, so its VM is never stranded.
@Suite struct RunMethodsFeaturePolicyTests {
    @Test func onlyANewRunIsACloudFeatureMethod() {
        #expect(AppControl.policyFeature(of: "runs.sandbox.create") == .cloud)
        #expect(AppControl.policyRefusal("runs.sandbox.create", disabled: [.cloud])?.code == "feature.disabled")
        #expect(AppControl.policyRefusal("runs.sandbox.create", disabled: []) == nil)
        for method in ["runs.wait", "runs.cancel"] {
            #expect(AppControl.policyFeature(of: method) == nil)
            #expect(AppControl.policyRefusal(method, disabled: [.cloud]) == nil)
        }
    }
}

/// What the CLI acts on: a definite refusal (rate limit, no backend) is never "the run may have
/// started", a server failure or an unreadable answer is, and an expired session is a sign-in.
@Suite struct RunErrorMappingTests {
    @Test func eachRunAPIFailureMapsToTheCodeTheCLIActsOn() {
        #expect(AppControl.runError(.http(status: 401, code: nil, message: nil)).code == "not_signed_in")
        #expect(AppControl.runError(.http(status: 403, code: "run_sandbox_unavailable", message: nil)).code == "run_sandbox_unavailable")
        #expect(AppControl.runError(.http(status: 429, code: "rate_limited", message: nil, action: nil, traceId: "t1")).code == "rate_limited")
        #expect(AppControl.runError(.http(status: 503, code: nil, message: nil)).code == "unavailable")
        #expect(AppControl.runError(.http(status: 404, code: "run_not_found", message: nil)).code == "run_not_found")
        #expect(AppControl.runError(.noBackend(URL(string: "http://127.0.0.1:1")!)).code == "no_backend")
        #expect(AppControl.runError(.transport("offline")).code == "unavailable")
        #expect(AppControl.runError(.decoding("bad")).code == "bad_response")
        #expect(AppControl.runError(.timedOut("/api/runs")).code == "timeout")
        // A timeout's message is the localized one, never the request path.
        #expect(!AppControl.runError(.timedOut("/api/runs/run-1/wait")).message.contains("/api/runs"))
    }
}
