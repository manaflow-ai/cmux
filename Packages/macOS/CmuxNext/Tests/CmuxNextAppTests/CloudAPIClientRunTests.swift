import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextControl
import Foundation
import Testing

/// `cmux run --sandboxed` (hq#3367) goes through these: the daemon's `cloud.runs.*`, whose create
/// retry, long-poll and deadline are cmux-cloud-api `runs.rs`'s (and its tests').
@Suite struct CloudAPIClientRunTests {
    @Test func aSandboxedRunIsOneDaemonCallUnderOneKey() async throws {
        let fake = FakeCloudAPI { _ in FakeCloudAPI.json(#"{"run":{"id":"run-1"},"receipt":{"ok":true}}"#) }
        let snapshot = try await fake.classic().runSandbox(task: "ls", agent: "codex", timeoutMs: 1_000, idempotencyKey: "key-1",
                                                           teardown: .seconds(2), callsMargin: .seconds(3))
        #expect(snapshot["receipt"] is [String: Any])
        #expect(fake.operations == ["cloud.runs.sandbox"])
        let args = try #require(fake.seen.first?.args)
        #expect(args["task"]?.stringValue == "ls")
        #expect(args["agent"]?.stringValue == "codex")
        #expect(args["idempotencyKey"]?.stringValue == "key-1")
        #expect(args["timeoutMs"]?.intValue == 1_000)
        #expect(args["teardownMs"]?.intValue == 2_000)
        #expect(args["callsMarginMs"]?.intValue == 3_000)
    }

    @Test func aFollowedRunIsStartedThenFollowedInPlaceOfThePoll() async throws {
        let fake = FakeCloudAPI { _ in FakeCloudAPI.json(#"{"id":"run-7"}"#) }
        let snapshot = try await fake.classic().runSandbox(task: "ls", idempotencyKey: "key-2") { id in
            Data(#"{"run":{"id":"\#(id)"},"receipt":{}}"#.utf8)
        }
        #expect((snapshot["run"] as? [String: Any])?["id"] as? String == "run-7")
        #expect(fake.operations == ["cloud.runs.start"])
        #expect(fake.seen.first?.args["idempotencyKey"]?.stringValue == "key-2")
    }

    @Test func waitIsCappedAtTheServerBound() async throws {
        let fake = FakeCloudAPI { _ in FakeCloudAPI.json(#"{"run":{"id":"run-1"}}"#) }
        _ = try await fake.classic().waitRun("run-1", timeoutMs: 60_000)
        #expect(fake.operations == ["cloud.runs.wait"])
        #expect(fake.seen.first?.args["timeoutMs"]?.intValue == 10_000)
    }

    @Test func aRefusalReadsAsTheTypedFailure() async {
        let fake = FakeCloudAPI { _ in
            throw FakeCloudAPI.refusal(#"{"kind":"http","status":403,"code":"run_sandbox_unavailable","message":null,"action":null,"trace_id":null}"#)
        }
        await #expect(throws: CloudAPIError.http(status: 403, code: "run_sandbox_unavailable", message: nil)) {
            _ = try await fake.classic().cancelRun("run-1")
        }
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
