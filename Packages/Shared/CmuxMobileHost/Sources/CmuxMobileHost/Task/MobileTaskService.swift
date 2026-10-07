import CmuxMobileWire

/// The task family on this host: the `task:<host>` projection, the policy, the
/// attachment resolver and the runner. Present only when the app registers a
/// runner; without it task ops keep their default refusal.
public struct MobileTaskService: Sendable {
    public let owner: TaskStreamOwner
    let runner: any MobileTaskRunner
    let policy: MobileTaskPolicy
    let attachments: any MobileTaskAttachmentResolver

    public init(owner: TaskStreamOwner, runner: any MobileTaskRunner, policy: MobileTaskPolicy,
                attachments: any MobileTaskAttachmentResolver) {
        self.owner = owner
        self.runner = runner
        self.policy = policy
        self.attachments = attachments
    }

    /// Runs one task op the caller already authorized: policy, attachment
    /// resolution for `context.install`, runner, then a refresh so the reply's
    /// seq covers the op's effects.
    func perform(op: String, params: JSONValue, workspaces: MobileWorkspaceState, context: MobileOpContext,
                 tx: String) async -> MobileOpOutcome {
        let tasks: MobileTaskStreamState
        do {
            tasks = try await owner.currentState()
        } catch {
            return .reject(tx: tx, MobileOpRejection(code: "owner.unreachable", message: "the task runner is unreachable",
                                                     retryable: true))
        }
        let allowed: MobileTaskOp
        switch policy.evaluate(op: op, params: params, workspaces: workspaces, tasks: tasks) {
        case .success(let value): allowed = value
        case .failure(let rejection): return .reject(tx: tx, rejection)
        }
        do {
            let value: JSONValue
            switch allowed {
            case .dispatch(var request):
                request.attachments = try await attachments.resolve(request.uploads, install: context.install)
                value = try await runner.dispatch(request, context: context).jsonValue
            case .cancel(let task):
                try await runner.cancel(task: task, context: context)
                value = .object([:])
            }
            await owner.refresh()
            return .result(tx: tx, value: value, sequence: await owner.headSeq)
        } catch let error as MobileDaemonError {
            return .reject(tx: tx, MobileOpRejection(code: error.code, message: error.message, retryable: error.retryable))
        } catch {
            return .reject(tx: tx, MobileOpRejection(code: "owner.unreachable", message: "the task runner did not answer",
                                                     retryable: true))
        }
    }

    /// `task.list` (read): the projected tasks, optionally by state, newest first.
    func list(_ params: JSONValue) async throws -> JSONValue {
        let state = try await owner.currentState()
        var tasks = state.tasks
        if let raw = params["state"]?.stringValue {
            guard let wanted = MobileTaskState(rawValue: raw) else {
                throw MobileDaemonError(code: "validation.invalid", message: "unknown task state \(raw)")
            }
            tasks = tasks.filter { $0.state == wanted }
        }
        if case .int(let limit)? = params["limit"] {
            tasks = Array(tasks.prefix(max(1, min(500, Int(limit)))))
        }
        return .object(["tasks": try JSONValue(encoding: tasks)])
    }
}
