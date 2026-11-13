import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextControl
import Foundation
import Testing

/// `cmux run --sandboxed` (hq#3367) goes through these: each is the daemon's `cloud.runs.*`
/// (cmux-cloud-api `runs.rs` sends the Run API's Idempotency-Key, retries a lost create once under
/// it and caps each wait), and every call answers the raw JSON.
struct CloudAPIClientRunTests {
    private static let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                                  process: [:], isDebugBuild: true)

    private func fake() -> CloudDaemonFake {
        CloudDaemonFake { operation, _ in
            switch operation {
            case "cloud.runs.wait": CloudDaemonFake.read(#"{"run":{"id":"run-1","status":"succeeded"},"receipt":{"schema":"cmux.run.receipt/v1"}}"#)
            default: CloudDaemonFake.value(#"{"id":"run-1","status":"queued"}"#)
            }
        }
    }

    private func api(_ fake: CloudDaemonFake, tokens: @escaping CloudAPIClient.Tokens = { ("access", "refresh") }) -> CloudAPIClient {
        CloudAPIClient(configuration: Self.configuration, tokens: tokens, teamID: { "team-1" }, daemon: fake.daemon)
    }

    @Test func createSendsTheKeyAndWaitIsCappedAtTheServerBound() async throws {
        let fake = fake()
        let api = api(fake)
        let created = try JSONSerialization.jsonObject(with: try await api.createSandboxRun(task: "hi", agent: "claude",
                                                                                            idempotencyKey: "key-1")) as? [String: Any]
        #expect(created?["id"] as? String == "run-1")
        let waited = try JSONSerialization.jsonObject(with: try await api.waitRun("run-1", timeoutMs: 60_000)) as? [String: Any]
        #expect((waited?["receipt"] as? [String: Any])?["schema"] as? String == "cmux.run.receipt/v1")
        #expect(fake.sent.map(\.operation) == ["cloud.runs.create", "cloud.runs.wait"])
        #expect(fake.sent.first?.args["idempotencyKey"] as? String == "key-1" && fake.sent.first?.args["agent"] as? String == "claude")
        #expect(fake.sent.last?.args["timeoutMs"] as? Int == 10_000)
        for sent in fake.sent {
            #expect(sent.params["auth"] as? String == "stack" && sent.params["refresh_token"] as? String == "refresh")
            #expect(sent.params["team"] as? String == "team-1")
        }
    }

    /// The composer's Sandboxed send: the daemon's start (its create and the create's one retry), then the follower's wait.
    @Test func runSandboxStartsThenFollowsTheRun() async throws {
        let fake = fake()
        let snapshot = try await api(fake).runSandbox(task: "hi", idempotencyKey: "key-9") { id in
            #expect(id == "run-1")
            return Data(#"{"run":{"id":"run-1"},"receipt":{}}"#.utf8)
        }
        #expect(snapshot["receipt"] is [String: Any])
        #expect(fake.sent.map(\.operation) == ["cloud.runs.start"])
        #expect(fake.sent.first?.args["idempotencyKey"] as? String == "key-9" && fake.sent.first?.args["timeoutMs"] as? Int == 600_000)
    }

    @Test func aSignInThatNeverAnswersStillEndsAtTheBound() async throws {
        // The token read ignores cancellation and never returns.
        let api = api(fake(), tokens: {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return ("access", "refresh")
        })
        let start = ContinuousClock.now
        await #expect(throws: CloudAPIError.timedOut("/api/runs")) {
            _ = try await api.runSandbox(task: "hi", timeoutMs: 50, teardown: .zero, callsMargin: .milliseconds(50)) { _ in Data() }
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
        let fake = fake()
        let api = api(fake)
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await api.runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "cancelled") { _ in Data() }
        }
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(fake.sent.isEmpty)
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
