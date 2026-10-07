import CmuxMobileHost
import CmuxMobileWire
import Testing

@Suite("task policy")
struct TaskPolicyTests {
    let policy = MobileTaskPolicy(hostID: "h_mac1", allowsDispatch: true)
    let tasks = MobileTaskStreamState(agents: [FakeTaskRunner.claude, FakeTaskRunner.codex], tasks: [
        MobileTask(id: "task_k1", host: "h_mac1", agent: "claude", state: .running, createdAt: 1),
    ])

    func evaluate(_ params: JSONValue, op: String = "task.dispatch", policy: MobileTaskPolicy? = nil)
        -> Result<MobileTaskOp, MobileOpRejection> {
        (policy ?? self.policy).evaluate(op: op, params: params, workspaces: FakeDaemon.sample, tasks: tasks)
    }

    func code(_ result: Result<MobileTaskOp, MobileOpRejection>) -> String? {
        if case .failure(let rejection) = result { return rejection.code }
        return nil
    }

    @Test func aValidDispatchCarriesOnlyAdvertisedValues() {
        let result = evaluate(["agent": "claude", "model": "opus", "effort": "high", "prompt": "Fix `make test`; rm -rf /",
                               "workspace": "ws_a1", "attachments": ["up_7Hq2"], "template": "fix"])
        #expect(result == .success(.dispatch(MobileTaskDispatch(
            agent: "claude", model: "opus", effort: "high", prompt: "Fix `make test`; rm -rf /", workspace: "ws_a1",
            uploads: ["up_7Hq2"], template: "fix"))))
    }

    @Test func dispatchIsOffUntilVerifiedOnThisMac() {
        let result = evaluate(["agent": "claude", "prompt": "go"], policy: MobileTaskPolicy(hostID: "h_mac1"))
        guard case .failure(let rejection) = result else { Issue.record("expected refusal"); return }
        #expect(rejection.code == "auth.forbidden")
        #expect(rejection.details?["reason"] == "spawn_unverified")
    }

    @Test func commandBearingParamsAreForbiddenBeforeAnythingElse() {
        for key in ["command", "argv", "env", "cwd", "shell", "script", "url"] {
            let result = evaluate(.object(["agent": "claude", "prompt": "go", key: "x"]),
                                  policy: MobileTaskPolicy(hostID: "h_mac1"))
            #expect(code(result) == "auth.forbidden")
            if case .failure(let rejection) = result { #expect(rejection.details == nil) }
        }
    }

    @Test func unknownParamsAreInvalid() {
        #expect(code(evaluate(["agent": "claude", "prompt": "go", "binary": "/bin/sh"])) == "validation.invalid")
    }

    @Test func onlyAdvertisedAvailableAgentsRun() {
        #expect(code(evaluate(["agent": "/usr/bin/python3", "prompt": "go"])) == "task.agent_unavailable")
        #expect(code(evaluate(["agent": "codex", "prompt": "go"])) == "task.agent_unavailable")
    }

    @Test func modelAndEffortMustBeOffered() {
        #expect(code(evaluate(["agent": "claude", "model": "--dangerously-skip-permissions", "prompt": "go"])) == "validation.invalid")
        #expect(code(evaluate(["agent": "claude", "model": "haiku", "effort": "high", "prompt": "go"])) == "validation.invalid")
        #expect(code(evaluate(["agent": "claude", "effort": "max", "prompt": "go"])) == "validation.invalid")
        // Without a model, effort follows the agent's default model.
        #expect(code(evaluate(["agent": "claude", "effort": "low", "prompt": "go"])) == nil)
    }

    @Test func promptIsBoundedDataWithoutNUL() {
        #expect(code(evaluate(["agent": "claude", "prompt": "  \n"])) == "validation.invalid")
        #expect(code(evaluate(["agent": "claude", "prompt": "a\u{0}b"])) == "validation.invalid")
        #expect(code(evaluate(["agent": "claude", "prompt": .string(String(repeating: "x", count: 100_001))])) == "validation.invalid")
    }

    @Test func workspacesAndHostsAreScopedToThisMac() {
        #expect(code(evaluate(["agent": "claude", "prompt": "go", "workspace": "ws_other1"])) == "workspace.not_found")
        #expect(code(evaluate(["agent": "claude", "prompt": "go", "workspace": "ws:ref"])) == "validation.invalid")
        #expect(code(evaluate(["agent": "claude", "prompt": "go", "host": "h_mac2"])) == "validation.invalid")
    }

    @Test func attachmentsAreUploadIdsNeverPaths() {
        #expect(code(evaluate(["agent": "claude", "prompt": "go", "attachments": ["/Users/me/.ssh/id_ed25519"]])) == "validation.invalid")
        #expect(code(evaluate(["agent": "claude", "prompt": "go", "attachments": .array(Array(repeating: "up_ab", count: 33))]))
            == "validation.invalid")
    }

    @Test func templatesAreLabels() {
        #expect(code(evaluate(["agent": "claude", "prompt": "go", "template": "$(whoami)"])) == "validation.invalid")
    }

    @Test func cancelNeedsAKnownTask() {
        #expect(evaluate(["task": "task_k1"], op: "task.cancel") == .success(.cancel(task: "task_k1")))
        #expect(code(evaluate(["task": "task_zz"], op: "task.cancel")) == "task.not_found")
        #expect(code(evaluate(["task": "task_k1", "reason": "x"], op: "task.cancel")) == "validation.invalid")
        #expect(code(evaluate(["task": "x"], op: "task.state.set")) == "auth.forbidden")
    }
}
