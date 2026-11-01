import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextControl
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

    /// The composer's Sandboxed send: running answers until the receipt, then the snapshot.
    nonisolated final class SandboxAPI: URLProtocol {
        nonisolated(unsafe) static var waits = 0
        nonisolated(unsafe) static var finishAfter = 2
        /// Creates whose answer is lost (the connection drops), and every create's key.
        nonisolated(unsafe) static var dropCreates = 0
        /// A wait that answers 200 with something that is no Run snapshot.
        nonisolated(unsafe) static var malformedWait = false
        nonisolated(unsafe) static var createKeys: [String?] = []
        /// Every create's bearer token.
        nonisolated(unsafe) static var createTokens: [String?] = []

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            var body = #"{"id":"run-9","status":"queued"}"#
            if url.path == "/api/runs" {
                Self.createKeys.append(request.value(forHTTPHeaderField: "Idempotency-Key"))
                Self.createTokens.append(request.value(forHTTPHeaderField: "Authorization"))
                if Self.dropCreates > 0 {
                    Self.dropCreates -= 1
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                    return
                }
            }
            if url.path.hasSuffix("/wait") {
                Self.waits += 1
                body = Self.malformedWait ? #"{"error":"internal"}"# : Self.waits > Self.finishAfter
                    ? #"{"run":{"id":"run-9","status":"succeeded"},"receipt":{"status":"succeeded","reply":"done"}}"#
                    : #"{"run":{"id":"run-9","status":"running"},"receipt":null}"#
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func sandboxAPI(tokens: @escaping CloudAPIClient.Tokens = { ("access", "refresh") }) -> CloudAPIClient {
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SandboxAPI.self]
        return CloudAPIClient(configuration: configuration, tokens: tokens, teamID: { nil },
                              session: URLSession(configuration: sessionConfiguration))
    }

    @Test func runSandboxWaitsUntilTheReceiptThenAnswersTheSnapshot() async throws {
        SandboxAPI.waits = 0
        SandboxAPI.finishAfter = 2
        SandboxAPI.dropCreates = 0
        let snapshot = try await sandboxAPI().runSandbox(task: "hi", timeoutMs: 60_000)
        #expect((snapshot["receipt"] as? [String: Any])?["reply"] as? String == "done")
        #expect(SandboxAPI.waits == 3)
    }

    @Test func aCreateWhoseAnswerWasLostIsSentOnceMoreUnderTheSameKey() async throws {
        SandboxAPI.waits = 0
        SandboxAPI.finishAfter = 0
        SandboxAPI.dropCreates = 1
        SandboxAPI.createKeys = []
        let snapshot = try await sandboxAPI().runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "send-1")
        #expect((snapshot["receipt"] as? [String: Any])?["reply"] as? String == "done")
        #expect(SandboxAPI.createKeys == ["send-1", "send-1"])
    }

    @Test func aRetryThatFailsAfterAnUncertainCreateStaysUncertain() async throws {
        SandboxAPI.waits = 0
        SandboxAPI.finishAfter = 0
        SandboxAPI.dropCreates = 2
        SandboxAPI.createKeys = []
        await #expect(throws: CloudAPIError.timedOut("/api/runs")) {
            _ = try await sandboxAPI().runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "send-2")
        }
        #expect(SandboxAPI.createKeys == ["send-2", "send-2"])
    }

    @Test func theRetryGoesWithTheFirstCreatesCredentials() async throws {
        // The server scopes the key per account: had another account signed in between the two
        // creates, its credentials would start a second Run. Each read of the tokens here is a new
        // account; both creates still carry the first.
        nonisolated final class Accounts: @unchecked Sendable { nonisolated(unsafe) var reads = 0 }
        let accounts = Accounts()
        SandboxAPI.waits = 0
        SandboxAPI.finishAfter = 0
        SandboxAPI.dropCreates = 1
        SandboxAPI.createKeys = []
        SandboxAPI.createTokens = []
        let api = sandboxAPI(tokens: {
            accounts.reads += 1
            return ("account-\(accounts.reads)", "refresh")
        })
        _ = try await api.runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "send-3")
        #expect(SandboxAPI.createKeys == ["send-3", "send-3"])
        #expect(SandboxAPI.createTokens == ["Bearer account-1", "Bearer account-1"])
    }

    @Test func aWaitAnswerThatIsNoSnapshotEndsAtOnce() async throws {
        SandboxAPI.waits = 0
        SandboxAPI.finishAfter = .max
        SandboxAPI.dropCreates = 0
        SandboxAPI.malformedWait = true
        defer { SandboxAPI.malformedWait = false }
        await #expect(throws: CloudAPIError.timedOut("/api/runs/run-9")) {
            _ = try await sandboxAPI().runSandbox(task: "hi", timeoutMs: 60_000)
        }
        #expect(SandboxAPI.waits == 1)
    }

    @Test func runSandboxStopsAtTheDeadline() async throws {
        SandboxAPI.waits = 0
        SandboxAPI.finishAfter = .max
        SandboxAPI.dropCreates = 0
        // The clock jumps past the deadline after the first wait: the loop stops instead of polling on.
        let start = ContinuousClock.now
        let calls = LockedCounter()
        await #expect(throws: CloudAPIError.timedOut("/api/runs/run-9")) {
            _ = try await sandboxAPI().runSandbox(task: "hi", timeoutMs: 30_000, teardown: .zero,
                                                  now: { calls.next() > 2 ? start + .seconds(3600) : start })
        }
        #expect(SandboxAPI.waits == 1)
    }

    @Test func aSignInThatNeverAnswersStillEndsAtTheBound() async throws {
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        // The token read ignores cancellation and never returns.
        let api = CloudAPIClient(configuration: configuration, tokens: {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return ("access", "refresh")
        }, teamID: { nil })
        let start = ContinuousClock.now
        await #expect(throws: CloudAPIError.timedOut("/api/runs")) {
            _ = try await api.runSandbox(task: "hi", timeoutMs: 50, teardown: .zero, callsMargin: .milliseconds(50))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func aServerOrHeaderCodeReachesThePageOnlyWhenThePageWordsIt() async {
        // The Sandboxed send's mapping (AgentPageChats.sandboxCode): the server's code when the page
        // knows it, `unavailable` for any other (it may name a provider handle), and a refusal before
        // anything was stored as a definite one (the tab may send again).
        let page = { (error: CloudAPIError) async -> String? in
            let reply = await AgentPaneReply.sandbox({ throw error }, code: AgentPageChats.sandboxCode)
            return (reply["error"] as? [String: Any])?["code"] as? String
        }
        #expect(await page(.http(status: 403, code: "run_sandbox_unavailable", message: nil)) == "run_sandbox_unavailable")
        #expect(await page(.http(status: 403, code: "provider_vm_abc123", message: "vm abc123")) == "unavailable")
        #expect(await page(.http(status: 500, code: nil, message: nil)) == "unavailable")
        #expect(await page(.http(status: 429, code: "rate_limited", message: nil)) == "unavailable_now")
        #expect(await page(.http(status: 401, code: nil, message: nil)) == "not_signed_in")
        #expect(await page(.noBackend(URL(string: "http://127.0.0.1:9")!)) == "unavailable_now")
        #expect(await page(.timedOut("/api/runs/run-9")) == "timeout")
        #expect(await page(.notSignedIn) == "not_signed_in")
    }

    @Test func aRunAPIWithNoSandboxedRunsSaysSoNotThatARunMayBeGoing() async {
        // The Run API before sandboxed Runs refuses a sandboxed body for want of a source or recipe,
        // before it stores anything: the page hears `run_sandbox_unavailable` ("not enabled yet"), a
        // definite refusal that frees the tab (AgentPaneSandboxRunTests), never `unavailable`.
        let page = { (error: CloudAPIError) async -> String? in
            let reply = await AgentPaneReply.sandbox({ throw error }, code: AgentPageChats.sandboxCode)
            return (reply["error"] as? [String: Any])?["code"] as? String
        }
        for code in ["run_source_required", "run_recipe_required"] {
            #expect(await page(.http(status: 400, code: code, message: "source.commit must be a commit SHA.")) == "run_sandbox_unavailable")
        }
        // The same code with another status is no proof nothing was stored.
        #expect(await page(.http(status: 500, code: "run_source_required", message: nil)) == "unavailable")
    }

    @Test func aCancelledCallerStartsNoRun() async throws {
        SandboxAPI.createKeys = []
        let api = sandboxAPI()
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await api.runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "cancelled")
        }
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(SandboxAPI.createKeys.isEmpty)
    }

    nonisolated final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }
}

/// A new sandboxed run belongs to the Cloud feature: an administrator who turns Cloud off turns
/// it off. Waiting on or cancelling a run that exists stays open, so its VM is never stranded.
@Suite struct RunMethodsFeaturePolicyTests {
    @Test func onlyANewRunIsACloudFeatureMethod() {
        #expect(ActionFeature(controlMethod: "runs.sandbox.create") == .cloud)
        #expect(ControlError.policyRefusal("runs.sandbox.create", disabled: [.cloud])?.code == "feature.disabled")
        #expect(ControlError.policyRefusal("runs.sandbox.create", disabled: []) == nil)
        for method in ["runs.wait", "runs.cancel"] {
            #expect(ActionFeature(controlMethod: method) == nil)
            #expect(ControlError.policyRefusal(method, disabled: [.cloud]) == nil)
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
