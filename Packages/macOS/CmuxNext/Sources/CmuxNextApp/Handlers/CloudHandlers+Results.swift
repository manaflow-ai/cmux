import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// What a Cloud action found, for whoever ran it: a person sees `text` in a
/// sheet titled `title`; a CLI, MCP, script or remote run gets `text` and
/// `fields` back as `action.run`'s `result`.
struct CloudAnswer {
    var title: String
    var text: String
    var copyable = true
    var fields: [String: ActionResultValue] = [:]
}

// How Cloud actions hand their results back to a caller that is not a person.
extension CloudHandlers {
    /// Runs Cloud work whose answer someone reads. A person's run shows it in
    /// a sheet, as before. Any other run (CLI, MCP, a script, another client)
    /// gets it as the run's `result` and nothing opens on the person's screen.
    /// `pendingAfter`: work that may outlast `action.run`'s result deadline (a
    /// snapshot) answers `pending` then and keeps going; its answer is logged.
    static func answer(_ label: String, _ invocation: ActionInvocation, _ context: AppActionContext,
                       pendingAfter: Duration? = nil, pending: [String: ActionResultValue] = [:],
                       _ work: @escaping @MainActor () async throws -> CloudAnswer) {
        guard origin(of: invocation) != .user else {
            return runTracked(label, context) {
                let answer = try await work()
                CloudPresenter.show(answer.title, answer.text, copyable: answer.copyable, in: window(context))
            }
        }
        let logger = context.services.cloud.logger
        result(label, context, pendingAfter: pendingAfter, pending: pending) {
            let answer = try await work()
            logger.info("\(label, privacy: .public): \(answer.text, privacy: .private)")
            return answer.fields.merging(["text": .string(answer.text)]) { field, _ in field }
        }
    }

    /// Runs Cloud work that produces `action.run`'s `result` fields, and shows
    /// nothing. A refusal (``ActionFailure``) reaches the caller as one. Work
    /// that outlasts `pendingAfter` answers `pending` (plus `pending: true`)
    /// and keeps running. A run nobody captures shows a failure as a sheet.
    static func result(_ label: String, _ context: AppActionContext,
                       pendingAfter: Duration? = nil, pending: [String: ActionResultValue] = [:],
                       _ work: @escaping @MainActor () async throws -> [String: ActionResultValue]) {
        let logger = context.services.cloud.logger
        let captured = context.services.registry.isCapturingWork
        // task-owner: the Cloud work itself; it runs to its end even after a `pending` answer.
        // main-hop-allow: the action's userBlocking rest (p06 rule 2), tracked for a capturing caller: `work` is main-actor async Cloud code; post has no userBlocking class (task 208)
        let inner: ActionResultWork = Task { @MainActor in
            do {
                return .success(try await work())
            } catch let failure as ActionFailure {
                if !captured { CloudPresenter.failure(failure, in: window(context)) }
                return .failure(ActionWorkFailure(refusal: failure.isNotFound ? .notFound : .unavailable, reason: failure.message))
            } catch {
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if !captured { CloudPresenter.failure(error, in: window(context)) }
                return .failure(ActionWorkFailure("\(label): \(CloudStrings.errorText(error))"))
            }
        }
        guard let pendingAfter else { return context.services.registry.track(result: inner) }
        // task-owner: the action run's answer: the work's, or `pending` once the wait ends.
        // main-hop-allow: the capturing caller's answer (an ActionResultWork): one Deadline race, resumed once on main to return
        let task: ActionResultWork = Task { @MainActor in
            await firstAnswer(inner, within: pendingAfter) ?? .success(pending.merging(["pending": .bool(true)]) { field, _ in field })
        }
        context.services.registry.track(result: task)
    }

    /// `work`'s answer if it comes within `wait`, else nil (the work keeps
    /// running). A ``Deadline`` race: awaiting an unstructured task's `value`
    /// ignores cancellation, so a task group racing it would wait for the
    /// work to end anyway; the race resumes at the limit and drops the late
    /// answer, and cancelling its wait leaves the work itself running.
    static func firstAnswer(_ work: ActionResultWork, within wait: Duration) async -> Result<[String: ActionResultValue], ActionWorkFailure>? {
        await Deadline(wait).value("CloudHandlers.answer") { await work.value }
    }

    /// `cloud new-machine` from a CLI or MCP: the run answers once the server
    /// returned the machine, with its id, so the caller can name it in the
    /// next command (`--target machine:<id>`). Its first workspace opens later,
    /// when its daemon is ready; the answer does not wait for that. The server
    /// may take minutes to provision: after ``createdMachineWait`` the run
    /// answers `pending` instead of timing out, so no caller reads a slow create
    /// as a failure and starts a second machine.
    static func reportCreatedMachine(_ creation: CloudMachineCreation, _ context: AppActionContext,
                                     wait: Duration = createdMachineWait) {
        let registry = context.services.registry
        guard registry.isCapturingWork else { return }
        let creations = context.services.cloud.creations
        let work = context.services.mainWork, deadlines = context.services.mainDeadlines
        // task-owner: the action run; it ends when the create settles or the wait ends.
        // main-hop-allow: the capturing caller's answer (an ActionResultWork): it reads the main-actor creation and session once settled
        let task: ActionResultWork = Task { @MainActor in
            let settled = await settledCreation(creation, in: creations, within: wait, work: work, deadlines: deadlines)
            switch settled {
            case .created?, .pending?, nil:
                guard let session = creation.session else {
                    return .success(["pending": .bool(true), "status": .string("creating"), "creation_id": .string(creation.id.uuidString.lowercased())])
                }
                return .success(createdMachineFields(session, workspaceID: creation.workspaceID))
            case .failed(let reason)?:
                // A refusal a paid plan lifts answers `cloud.plan.required` and names the plan, so a
                // CLI or agent caller can start that plan's checkout (`cmux billing checkout --plan`).
                if let refusal = creation.planRefusal {
                    return .failure(ActionWorkFailure(code: planRequiredCode, reason: "new Cloud machine: \(reason) (plan: \(refusal.plan))"))
                }
                return .failure(ActionWorkFailure("new Cloud machine: \(reason)"))
            case .gone?:
                // Declined in the confirmation (an agent's create asks the person first), or dismissed.
                return .failure(ActionWorkFailure(refusal: .unavailable, reason: CloudStrings.createDeclined))
            }
        }
        registry.track(result: task)
    }

    /// The error code of a `cloud new-machine` refused for a paid plan, as the Cloud contract names it.
    static let planRequiredCode = "cloud.plan.required"

    /// How long `cloud new-machine` waits for the server's machine before it
    /// answers `pending`: inside `action.run`'s 40 s result deadline.
    static let createdMachineWait: Duration = .seconds(30)

    /// The creation's first state that is not `pending`, or nil after `limit`: a ``FirstValueWait`` of
    /// the creation in the automation class (only a capturing caller, an agent or the CLI, waits on it).
    static func settledCreation(_ creation: CloudMachineCreation, in creations: CloudCreations, within limit: Duration,
                                work: MainWorkScheduler, deadlines: MainDeadlineScheduler) async -> CreatedMachine? {
        // A wait dropped unanswered answers as the limit does: still pending.
        try? await withOnceContinuation { (continuation: OnceContinuation<CreatedMachine?, OnceContinuationError>) in
            FirstValueWait<CreatedMachine>.start(.automation, owner: "CloudHandlers.createdMachine", within: limit, work: work, deadlines: deadlines) {
                let state = CreatedMachine(creation, in: creations)
                return state == .pending ? nil : state
            } then: { state in
                continuation.resume(returning: state)
            }
        }
    }

    /// How long a run that answers `pending` itself (``createRequested(_:flow:window:_:)``) lets the create settle:
    /// past the server's same-key create retries (``CloudService/inProgressRetries`` 15 s apart, ~17.5 min).
    static let creationSettleLimit: Duration = .seconds(1800)

    /// ``settledCreation(_:in:within:work:deadlines:)`` bounded by ``creationSettleLimit``.
    static func settledCreation(_ creation: CloudMachineCreation, in creations: CloudCreations,
                                services: AppServices) async -> CreatedMachine? {
        await settledCreation(creation, in: creations, within: creationSettleLimit, work: services.mainWork, deadlines: services.mainDeadlines)
    }

    static func createdMachineFields(_ session: CloudMachineSession, workspaceID: String?) -> [String: ActionResultValue] {
        var fields: [String: ActionResultValue] = [
            "machine_id": .string(session.machineID),
            "title": .string(session.machine.title),
            "status": .string(session.effectiveStatus.rawValue),
            "target": .string("machine:\(session.machineID)"),
        ]
        if let workspaceID { fields["workspace_id"] = .string(workspaceID) }
        return fields
    }

    /// The longest a CLI or agent `cloud exec` runs its command (the Cloud
    /// API's `timeoutMs`): its HTTP request gets 5 s more, inside
    /// `action.run`'s 40 s result deadline.
    static let execTimeoutMs = 25_000
}

/// Where a creation is, as a value an observation can compare.
nonisolated enum CreatedMachine: Equatable, Sendable {
    case pending
    case created
    case failed(String)
    /// No longer listed: declined, dismissed or its machine removed.
    case gone

    @MainActor init(_ creation: CloudMachineCreation, in creations: CloudCreations) {
        guard creations.all.contains(where: { $0 === creation }) else {
            self = creation.session == nil ? .gone : .created
            return
        }
        if creation.session != nil {
            self = .created
        } else if case .failed(let reason) = creation.phase {
            self = .failed(reason)
        } else {
            self = .pending
        }
    }
}
