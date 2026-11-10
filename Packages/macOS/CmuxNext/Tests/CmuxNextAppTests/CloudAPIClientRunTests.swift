import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextControl
import Foundation
import Testing

/// `cmux run --sandboxed` and the Sandboxed send (hq#3367) go through these: each Run call is the cmux
/// daemon's `cloud.runs.*`, sent as one `cmux cloud api` request on the child's stdin (never classic
/// Cloud's `/api/runs`), and its answer line passes through as the body's JSON or as the ``CloudAPIError``
/// its failure names. A fake child stands in for the bundled cmux.
@Suite(.serialized)
struct CloudAPIClientRunTests {
    /// What the fake child prints for the `index`th request of `call` (0-based), or throws as the child runner does.
    typealias Script = @Sendable (_ call: String, _ args: [String: Any], _ index: Int) throws -> String

    /// The bundled cmux's stand-in: records every request it is given and prints `script`'s line.
    nonisolated final class FakeDaemon: @unchecked Sendable {
        // @unchecked: `seen` is read and written only under `lock`.
        private let lock = NSLock()
        private var seen: [(call: String, request: [String: Any])] = []
        private let script: Script

        init(_ script: @escaping Script) { self.script = script }

        var requests: [[String: Any]] { lock.withLock { seen.map(\.request) } }

        /// The args of every request of `call`, in order.
        func args(_ call: String) -> [[String: Any]] {
            lock.withLock { seen.filter { $0.call == call }.map { $0.request["args"] as? [String: Any] ?? [:] } }
        }

        func run(_ input: Data) throws -> Data {
            let request = (try JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
            let call = request["call"] as? String ?? ""
            let index = lock.withLock { () -> Int in
                seen.append((call, request))
                return seen.filter { $0.call == call }.count - 1
            }
            return Data((try script(call, request["args"] as? [String: Any] ?? [:], index) + "\n").utf8)
        }
    }

    nonisolated static let created = #"{"ok":true,"body":{"id":"run-9","status":"queued","attempts":[{"id":"a1","ordinal":1,"status":"queued"}],"environment":"sandboxed","image":null}}"#
    nonisolated static let running = #"{"ok":true,"body":{"run":{"id":"run-9","status":"running"},"attempts":[],"artifacts":[],"receipt":null}}"#
    nonisolated static let done = #"{"ok":true,"body":{"run":{"id":"run-9","status":"succeeded"},"attempts":[],"artifacts":[],"receipt":{"status":"succeeded","reply":"done"}}}"#

    private func api(_ daemon: FakeDaemon?, access: @escaping @Sendable () async throws -> String = { "access" }) -> CloudAPIClient {
        var api = CloudAPIClient.workerMachines(baseURL: URL(string: "https://owner.standin.invalid") ?? URL(fileURLWithPath: "/"),
                                                accessToken: access, teamID: { "team_cmux" })
        if let daemon { api.daemonCall = { input, _ in try daemon.run(input) } }
        return api.runningAs(Self.account)
    }

    nonisolated static let account = CloudAPIClient.RunAccount(user: "u1", team: "t1")

    /// A daemon whose create answers (after `dropCreates` lost answers) and whose wait has the receipt after `finishAfter` waits.
    private func sandbox(finishAfter: Int = 0, dropCreates: Int = 0) -> FakeDaemon {
        FakeDaemon { call, _, index in
            if call == "runs.create" {
                if index < dropCreates { throw CloudMachineIO.NoAnswer(dispatched: true) }
                return Self.created
            }
            return index >= finishAfter ? Self.done : Self.running
        }
    }

    @Test func eachCallIsTheDaemonsOpWithTheRequestOnStdin() async throws {
        let daemon = FakeDaemon { call, _, _ in
            switch call {
            case "runs.create": Self.created
            case "runs.wait": Self.done
            default: #"{"ok":true,"body":{"run":{"id":"run-9","status":"cancelled"},"receipt":null}}"#
            }
        }
        let api = api(daemon)
        let created = try JSONSerialization.jsonObject(with: try await api.createSandboxRun(task: "hi", agent: "claude", timeoutMs: 30_000,
                                                                                            idempotencyKey: "key-1")) as? [String: Any]
        #expect(created?["id"] as? String == "run-9")
        let waited = try JSONSerialization.jsonObject(with: try await api.waitRun("run-9", timeoutMs: 60_000)) as? [String: Any]
        #expect((waited?["receipt"] as? [String: Any])?["reply"] as? String == "done")
        let cancelled = try JSONSerialization.jsonObject(with: try await api.cancelRun("run-9")) as? [String: Any]
        #expect((cancelled?["run"] as? [String: Any])?["status"] as? String == "cancelled")

        let requests = daemon.requests
        #expect(requests.map { $0["call"] as? String } == ["runs.create", "runs.wait", "runs.cancel"])
        for request in requests {
            #expect(request["auth"] as? String == "owner")
            #expect(request["credential"] as? String == "access")
            #expect(request["team"] as? String == "team_cmux")
            #expect(request["api"] as? String == "https://owner.standin.invalid")
        }
        let create = try #require(daemon.args("runs.create").first)
        #expect(create["task"] as? String == "hi")
        #expect(create["agent"] as? String == "claude")
        #expect(create["timeoutMs"] as? Int == 30_000)
        #expect(create["idempotencyKey"] as? String == "key-1")
        #expect(create["image"] == nil && create["environment"] == nil)
        // The wait is held at most 10 s.
        #expect(daemon.args("runs.wait").first?["timeoutMs"] as? Int == 10_000)
        #expect(daemon.args("runs.wait").first?["id"] as? String == "run-9")
        #expect(daemon.args("runs.cancel").first?["id"] as? String == "run-9")
    }

    @Test func aFailureMapsToTheCloudAPIErrorItNames() async throws {
        func failing(_ failure: String) async -> (any Error)? {
            let api = api(FakeDaemon { _, _, _ in #"{"ok":false,"error":"# + failure + "}" })
            do { _ = try await api.waitRun("run-9", timeoutMs: 10_000) } catch { return error }
            return nil
        }
        let conflict = #"{"kind":"http","status":409,"code":"run_idempotency_conflict","message":"key reused","action":"retry","trace_id":"t1"}"#
        #expect(await failing(conflict) as? CloudAPIError
            == .http(status: 409, code: "run_idempotency_conflict", message: "key reused", action: "retry", traceId: "t1"))
        #expect(await failing(#"{"kind":"http","status":400,"code":"run_image_invalid"}"#) as? CloudAPIError
            == .http(status: 400, code: "run_image_invalid", message: nil))
        #expect(await failing(#"{"kind":"http","status":404,"code":"run_not_found","message":"no run"}"#) as? CloudAPIError
            == .http(status: 404, code: "run_not_found", message: "no run"))
        #expect(await failing(#"{"kind":"timed_out","path":"cloud.runs/run-9"}"#) as? CloudAPIError == .timedOut("cloud.runs/run-9"))
        #expect(await failing(#"{"kind":"timed_out"}"#) as? CloudAPIError == .timedOut("cloud.runs.wait"))
        #expect(await failing(#"{"kind":"transport","message":"the cmux daemon could not be reached"}"#) as? CloudAPIError
            == .transport("the cmux daemon could not be reached"))
        #expect(await failing(#"{"kind":"no_backend"}"#) as? CloudAPIError == .noBackend(URL(string: "https://owner.standin.invalid") ?? URL(fileURLWithPath: "/")))
        #expect(await failing(#"{"kind":"plan_required","plan":"max","upgrade_url":"https://cmux.com/pricing"}"#) as? CloudAPIError
            == .planRequired(message: nil, upgradeURL: URL(string: "https://cmux.com/pricing"), plan: "max"))
        #expect(await failing(#"{"kind":"decoding","message":"bad body"}"#) as? CloudAPIError == .decoding("bad body"))
        // A refusal the AppControl mapping words, end to end.
        #expect(AppControl.runError(.http(status: 400, code: "run_image_invalid", message: nil)).code == "run_image_invalid")
    }

    @Test func noAnswerIsTransportOrUncertainNeverHTTP() async throws {
        // No bundled cmux: nothing runs, and nothing falls back to classic Cloud.
        await #expect(throws: CloudAPIError.transport("cmux is not available")) {
            _ = try await api(nil).createSandboxRun(task: "hi", idempotencyKey: "k")
        }
        // A child that never started: nothing ran.
        await #expect(throws: CloudAPIError.transport("cmux is not available")) {
            _ = try await api(FakeDaemon { _, _, _ in throw CloudMachineIO.NoAnswer(dispatched: false) }).cancelRun("run-9")
        }
        // Started, then killed or crashed: the call may have run.
        await #expect(throws: CloudAPIError.timedOut("cloud.runs.cancel")) {
            _ = try await api(FakeDaemon { _, _, _ in throw CloudMachineIO.NoAnswer(dispatched: true) }).cancelRun("run-9")
        }
        // A line that is no answer.
        await #expect(throws: CloudAPIError.transport("cmux did not answer cloud.runs.wait")) {
            _ = try await api(FakeDaemon { _, _, _ in "panicked" }).waitRun("run-9", timeoutMs: 10_000)
        }
    }

    @Test func runSandboxWaitsUntilTheReceiptThenAnswersTheSnapshot() async throws {
        let daemon = sandbox(finishAfter: 2)
        let snapshot = try await api(daemon).runSandbox(task: "hi", timeoutMs: 60_000)
        #expect((snapshot["receipt"] as? [String: Any])?["reply"] as? String == "done")
        #expect(daemon.args("runs.wait").count == 3)
        #expect(daemon.args("runs.wait").allSatisfy { $0["id"] as? String == "run-9" })
    }

    @Test func aCreateWhoseAnswerWasLostIsSentOnceMoreUnderTheSameKey() async throws {
        let daemon = sandbox(dropCreates: 1)
        let snapshot = try await api(daemon).runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "send-1")
        #expect((snapshot["receipt"] as? [String: Any])?["reply"] as? String == "done")
        #expect(daemon.args("runs.create").map { $0["idempotencyKey"] as? String } == ["send-1", "send-1"])
    }

    @Test func aRefusedCreateIsNotSentAgain() async throws {
        let daemon = FakeDaemon { _, _, _ in #"{"ok":false,"error":{"kind":"http","status":400,"code":"run_agent_invalid"}}"# }
        await #expect(throws: CloudAPIError.http(status: 400, code: "run_agent_invalid", message: nil)) {
            _ = try await api(daemon).runSandbox(task: "hi", agent: "nope", timeoutMs: 60_000, idempotencyKey: "send-0")
        }
        #expect(daemon.args("runs.create").count == 1)
        #expect(daemon.args("runs.wait").isEmpty)
    }

    @Test func aRetryThatFailsAfterAnUncertainCreateStaysUncertain() async throws {
        let daemon = sandbox(dropCreates: 2)
        await #expect(throws: CloudAPIError.timedOut("cloud.runs")) {
            _ = try await api(daemon).runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "send-2")
        }
        #expect(daemon.args("runs.create").map { $0["idempotencyKey"] as? String } == ["send-2", "send-2"])
    }

    @Test func theRetryGoesWithTheFirstCreatesCredentials() async throws {
        // Each read of the token here is a new account; both creates still carry the first.
        let accounts = LockedCounter()
        let daemon = sandbox(dropCreates: 1)
        _ = try await api(daemon, access: { "account-\(accounts.next())" }).runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "send-3")
        let creates = daemon.requests.filter { $0["call"] as? String == "runs.create" }
        #expect(creates.map { $0["credential"] as? String } == ["account-1", "account-1"])
        #expect(creates.map { ($0["args"] as? [String: Any])?["idempotencyKey"] as? String } == ["send-3", "send-3"])
    }

    /// The account the person sent under goes with the create and its retry, so the daemon starts nothing
    /// under another one; a client with no such account sends no create at all (Codex's reviews of #39022 at
    /// 1bf18b3d and 551a7dca, F1: every caller of create, the composer's and the control API's alike).
    /// Codex's review of #39022 at e59d43c8 (F1): a Run the app followed from before the daemon ran Runs (its saved
    /// record has no backend) is classic Cloud's. Its wait and cancel carry the classic API, the Run's team and the Stack
    /// session, so the daemon drains it there (cmux-cloud-api `classic_runs`); a create never carries them.
    @Test func aRunFromBeforeTheUpgradeIsWaitedOnAndCancelledWithTheClassicSession() async throws {
        let daemon = FakeDaemon { _, _, _ in Self.done }
        let classic = CloudAPIClient(baseURL: URL(string: "https://classic.standin.invalid") ?? URL(fileURLWithPath: "/"),
                                     tokens: { ("stack-access", "stack-refresh") }, teamID: { "team_now" },
                                     session: CloudAPIClient.noStoreTransport, appVersion: "cmux-next")
        let api = api(daemon).drainingClassic(classic).pinningTeam("team_stack")
        _ = try await api.waitRun("r-old", timeoutMs: 1_000)
        _ = try await api.cancelRun("r-old")
        #expect(daemon.requests.count == 2)
        for request in daemon.requests {
            #expect(request["credential"] as? String == "stack-access")
            #expect(request["refresh"] as? String == "stack-refresh")
            let args = request["args"] as? [String: Any]
            #expect(args?["id"] as? String == "r-old")
            #expect(args?["classicApi"] as? String == "https://classic.standin.invalid")
            #expect(args?["classicTeam"] as? String == "team_stack")
        }
        _ = try await api.createSandboxRun(task: "hi", idempotencyKey: "k-new")
        #expect(daemon.requests.last?["refresh"] == nil)
        #expect((daemon.requests.last?["args"] as? [String: Any])?["classicApi"] == nil)
    }

    @Test func everyCreateNamesTheAccountItWasSentUnderAndNoneGoesWithout() async throws {
        let daemon = sandbox(dropCreates: 1)
        _ = try await api(daemon).runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "send-4")
        let expected = daemon.args("runs.create").map { $0["expectedAccount"] as? [String: String] }
        #expect(expected == [["user_id": "u1", "team_id": "t1"], ["user_id": "u1", "team_id": "t1"]])
        _ = try await api(daemon).runningAs(.init(user: "u2", team: nil)).createSandboxRun(task: "hi", idempotencyKey: "send-5", incognito: true)
        #expect(daemon.args("runs.create").last?["expectedAccount"] as? [String: String] == ["user_id": "u2", "team_id": ""])
        #expect(daemon.args("runs.create").last?["incognito"] as? Bool == true)
        let creates = daemon.args("runs.create").count
        await #expect(throws: CloudAPIError.notSignedIn) {
            _ = try await api(daemon).runningAs(nil).createSandboxRun(task: "hi", idempotencyKey: "send-6")
        }
        #expect(daemon.args("runs.create").count == creates, "no create goes without its account")
    }

    @Test func aWaitAnswerThatIsNoSnapshotEndsAtOnce() async throws {
        let daemon = FakeDaemon { call, _, _ in call == "runs.create" ? Self.created : #"{"ok":true,"body":{"error":"internal"}}"# }
        await #expect(throws: CloudAPIError.timedOut("cloud.runs/run-9")) {
            _ = try await api(daemon).runSandbox(task: "hi", timeoutMs: 60_000)
        }
        #expect(daemon.args("runs.wait").count == 1)
    }

    @Test func aFailedWaitIsNoReceiptInTimeNeverARefusal() async throws {
        let daemon = FakeDaemon { call, _, _ in
            call == "runs.create" ? Self.created : #"{"ok":false,"error":{"kind":"http","status":404,"code":"run_not_found"}}"#
        }
        await #expect(throws: CloudAPIError.timedOut("cloud.runs/run-9")) {
            _ = try await api(daemon).runSandbox(task: "hi", timeoutMs: 60_000)
        }
    }

    @Test func runSandboxStopsAtTheDeadline() async throws {
        let daemon = sandbox(finishAfter: .max)
        // The clock jumps past the deadline after the first wait: the loop stops instead of polling on.
        let start = ContinuousClock.now
        let calls = LockedCounter()
        await #expect(throws: CloudAPIError.timedOut("cloud.runs/run-9")) {
            _ = try await api(daemon).runSandbox(task: "hi", timeoutMs: 30_000, teardown: .zero,
                                                 now: { calls.next() > 2 ? start + .seconds(3600) : start })
        }
        #expect(daemon.args("runs.wait").count == 1)
    }

    @Test func aSignInThatNeverAnswersStillEndsAtTheBound() async throws {
        let daemon = sandbox()
        // The token read ignores cancellation and never returns.
        let api = api(daemon, access: {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return "access"
        })
        let start = ContinuousClock.now
        await #expect(throws: CloudAPIError.timedOut("cloud.runs")) {
            _ = try await api.runSandbox(task: "hi", timeoutMs: 50, teardown: .zero, callsMargin: .milliseconds(50))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(daemon.requests.isEmpty)
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
        #expect(await page(.timedOut("cloud.runs/run-9")) == "timeout")
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
        let daemon = sandbox()
        let api = api(daemon)
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await api.runSandbox(task: "hi", timeoutMs: 60_000, idempotencyKey: "cancelled")
        }
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(daemon.args("runs.create").isEmpty)
    }

    nonisolated final class LockedCounter: @unchecked Sendable {
        // @unchecked: `count` is read and written only under `lock`.
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
        #expect(AppControl.runError(.timedOut("cloud.runs")).code == "timeout")
        // A timeout's message is the localized one, never the request path.
        #expect(!AppControl.runError(.timedOut("cloud.runs/run-1")).message.contains("cloud.runs"))
    }
}
