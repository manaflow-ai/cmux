import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextControl
import Foundation
import Testing

/// `cmux run --sandboxed` (hq#3367) goes through these. The Run API's calls, the create's retry
/// under its key and the long-poll to the receipt are cmux-tui's (`cli/cloud_api/runs.rs`, with their
/// tests); this checks what the app hands it, and the deadline that holds even when sign-in hangs.
@Suite(.serialized)
struct CloudAPIClientRunTests {
    @Test func createWaitAndCancelHandTheirArgumentsOn() async throws {
        let cmux = try FakeBundledCmux(answer: #"{"ok":true,"body":{"id":"run-1","status":"queued"}}"#)
        defer { cmux.remove() }
        let api = cmux.classic()
        let created = try JSONSerialization.jsonObject(with: try await api.createSandboxRun(task: "hi", agent: "claude",
                                                                                            idempotencyKey: "key-1")) as? [String: Any]
        #expect(created?["id"] as? String == "run-1")
        _ = try await api.waitRun("run-1", timeoutMs: 60_000)
        _ = try await api.cancelRun("run-1")
        #expect(cmux.calls == ["runs.create", "runs.wait", "runs.cancel"])
        let create = try #require(cmux.request(1)["args"] as? [String: Any])
        #expect(create["task"] as? String == "hi")
        #expect(create["agent"] as? String == "claude")
        #expect(create["idempotencyKey"] as? String == "key-1")
        #expect((cmux.request(2)["args"] as? [String: Any])?["timeoutMs"] as? Int == 60_000)
    }

    @Test func runSandboxHandsTheWholeRunToCmuxAndAnswersItsSnapshot() async throws {
        let cmux = try FakeBundledCmux(answer: #"{"ok":true,"body":{"run":{"id":"run-9","status":"succeeded"},"receipt":{"status":"succeeded","reply":"done"}}}"#)
        defer { cmux.remove() }
        let snapshot = try await cmux.classic().runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "send-1",
                                                           teardown: .seconds(3), callsMargin: .milliseconds(1_500))
        #expect((snapshot["receipt"] as? [String: Any])?["reply"] as? String == "done")
        #expect(cmux.calls == ["runs.sandbox"])
        let args = try #require(cmux.request(1)["args"] as? [String: Any])
        #expect(args["idempotencyKey"] as? String == "send-1")
        #expect(args["timeoutMs"] as? Int == 60_000)
        #expect(args["teardownMs"] as? Int == 3_000)
        #expect(args["callsMarginMs"] as? Int == 1_500)
    }

    /// With a follower the app starts the Run (its create and the retry under its key) and waits in
    /// its follower, not in a poll of its own.
    @Test func aFollowedRunIsStartedThenFollowed() async throws {
        let cmux = try FakeBundledCmux(answer: #"{"ok":true,"body":{"id":"run-9","status":"queued"}}"#)
        defer { cmux.remove() }
        let snapshot = try await cmux.classic().runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "send-2") { id in
            Data(#"{"run":{"id":"\#(id)"},"receipt":{"status":"succeeded"}}"#.utf8)
        }
        #expect((snapshot["run"] as? [String: Any])?["id"] as? String == "run-9")
        #expect(cmux.calls == ["runs.start"])
    }

    /// The uncertain create cmux reports stays uncertain: never a refusal the page could take as "nothing runs".
    @Test func anUncertainCreateStaysUncertain() async throws {
        let cmux = try FakeBundledCmux(answer: #"{"ok":false,"error":{"kind":"timed_out","path":"/api/runs"}}"#)
        defer { cmux.remove() }
        await #expect(throws: CloudAPIError.timedOut("/api/runs")) {
            _ = try await cmux.classic().runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "send-3")
        }
    }

    @Test func aSignInThatNeverAnswersStillEndsAtTheBound() async throws {
        // The token read ignores cancellation and never returns.
        let api = CloudAPIClient(configuration: FakeBundledCmux.configuration, tokens: {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return ("access", "refresh")
        }, teamID: { nil }, cli: nil)
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
        let cmux = try FakeBundledCmux()
        defer { cmux.remove() }
        let api = cmux.classic()
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await api.runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "cancelled")
        }
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(cmux.runs == 0)
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
