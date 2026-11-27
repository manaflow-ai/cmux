import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import os

/// Creates one Cloud machine through the Cloud app server (cx-t2rz), with
/// the person in the loop for the G8 approval (cx-wb5.65):
///
/// 1. A create that no person started (an agent, the CLI, a script) first
///    shows the native confirmation; nothing is sent until a person clicks.
/// 2. `cloud.machine.create` goes once with one idempotency key and origin
///    `user` (the verified app; the server refuses a money op otherwise).
/// 3. The Mac relay calls it with the install token, so the backend answers
///    `approval.pending {request}`. The flow answers that exact request as
///    the person's session (`feed.answer`), then retries with the SAME key
///    until the op's answer arrives (bounded; the approved op runs in the
///    backend after the answer).
///
/// The flow answers an approval only after a person's native click: their
/// own gesture, or step 1's confirmation (a no sends nothing more).
@MainActor
struct CloudMachineCreateFlow {
    /// What the person confirms: the exact machine the create asks for.
    struct Machine: Equatable, Sendable {
        var name: String?
        var cpu: Int, memoryMB: Int
        /// `sizeShown` is false for the legacy create, whose size the plan picks: the person sees no size.
        var diskMB: Int, sizeShown = true
        /// The agent chat (acpmux session) that asked; its card goes when that chat does.
        var askedBy: String?
    }

    enum Prompt: Equatable {
        /// A create that no person started asks first.
        case agentRequest(Machine)
        /// The backend holds the create for the person's approval.
        case approval(request: String, Machine)
    }

    /// Why a create needs a plan upgrade.
    struct Upgrade: Equatable, Sendable {
        typealias Reason = CloudUpgradeReason
        var reason: Reason
    }

    /// Whether the plan lets a create go out.
    enum Gate: Equatable { case allowed, upgrade(Upgrade) }

    /// The plan gate from the last known limits; unknown limits, or a cap the server makes room at (`makesRoom`), leave it to the server.
    static func gate(_ limits: CloudMachineLimits?, makesRoom: Bool = false) -> Gate {
        switch CloudStartCore().launchGate(limits, makesRoom: makesRoom) {
        case .allowed: .allowed
        case .freePlan: .upgrade(Upgrade(reason: .freePlan))
        case .atLimit(let max): .upgrade(Upgrade(reason: .atLimit(max)))
        }
    }

    // app-type-allow: an existing enum that gains one case (upgradeRequired)
    enum Failure: Error, Equatable {
        /// The person declined the confirmation; nothing was created.
        case declined
        /// The approval was answered, and the backend still held the create
        /// after every retry; the request stays in the feed. `lastRunError`: why the backend's approved run went back to pending.
        case stillPending(request: String, lastRunError: String? = nil)
        /// A pending answer without its request id (a protocol break).
        case noApprovalRequest
        /// The plan cannot create a machine; nothing was created. A person's create then shows the cap card
        /// (``CloudService/createMachine``, ``CloudMachineCap``); an agent's shows none and reports the refusal.
        case upgradeRequired(CloudUpgradeReason)
    }

    var run: CloudAppOp
    /// The native confirmation sheet; true only for a person's click.
    var confirm: @MainActor (Prompt) async -> Bool
    /// Answers approval `request` as the person's own session, only when it holds `op` with exactly `params`; returns the run's answer when the answer call carried it.
    var approve: @MainActor (_ request: String, _ op: String, _ params: JSONValue) async throws -> JSONValue?
    /// Waits before the next same-key retry after the approval (cancellable).
    var pause: @MainActor (_ attempt: Int) async throws -> Void
    /// Rust checks the selected backend's capabilities before an option-bearing create is sent.
    var validateOptions: @MainActor (_ params: JSONValue) async throws -> Void = { _ in }
    var beside: @MainActor () async -> Void = {} // runs beside the first call (a create's `user.ensure`), awaited before an approval is answered and before an answer returns, so nothing the approved op runs goes ahead of it
    var newKey: () -> String = { UUID().uuidString }
    /// How long the same-key calls go on after the approval before ``Failure/stillPending`` (the op call's own timeout), read on `now`.
    var patience: Duration = CloudAppOpRunner.timeout, now: @MainActor () -> ContinuousClock.Instant = { .now }

    /// The default machine named `name` (trimmed; empty is none): 2 vCPU, 4 GB, 20 GB disk, the platform's spare size (cmux-platform#1756),
    /// so a start claims a warm spare; a larger folder raises the disk (`atLeast`); `sizeShown` false when the plan picks the size.
    static func named(_ name: String?, sizeShown: Bool = true, askedBy: String? = nil) -> Machine {
        let made = CloudStartCore().defaultMachine(named: name)
        return Machine(name: made.name, cpu: made.cpu, memoryMB: made.memoryMb, diskMB: made.diskMb, sizeShown: sizeShown, askedBy: askedBy)
    }

    /// Creates a machine; `startedByPerson` is true for the person's own
    /// gesture in this app (click, menu, palette, key). Returns the machine
    /// record (contract 1.2). `askedBy`: the agent chat that asked, if one did.
    /// `key`: the creation's own idempotency key, so its Retry is the same create
    /// (the backend answers the first machine for it); a fresh one when none.
    /// `environment`: boot it in that Cloud environment (`cloud.environment.boot`)
    /// instead of a plain `cloud.machine.create`; the same confirmation and approval.
    /// `approved`: the approval an earlier attempt with `key` answered; `onApproved` hears each new answer.
    /// `answering`: the approval an earlier attempt with `key` began answering; `onAnswering` hears each, before it goes out.
    /// `madeRoom` hears the machine the server paused to make room at the cap (``CloudMachineCap/madeRoom(_:)``); `answered`, the whole answer (its spare report).
    func create(name: String?, startedByPerson: Bool, asksFirst: Bool = true, askedBy: String? = nil, key: String? = nil, approved: String? = nil,
                onApproved: @MainActor (String) -> Void = { _ in }, answering: String? = nil, onAnswering: @MainActor (String) -> Void = { _ in },
                gate: Gate = .allowed, environment: String? = nil, request: CloudMachineRequest? = nil,
                madeRoom: @MainActor (JSONValue) -> Void = { _ in }, answered: @MainActor (JSONValue) -> Void = { _ in }) async throws -> JSONValue {
        if case .upgrade(let need) = gate { throw Failure.upgradeRequired(need.reason) }
        let machine = Self.named(name, askedBy: askedBy)
        // A person's own gesture is the confirmation, so the backend's hold gets no second prompt.
        if !startedByPerson, asksFirst { guard await confirm(.agentRequest(machine)) else { throw Failure.declined } }
        let sized: (cpu: Int, memoryMb: Int, diskMb: Int) = request?.atLeast(cpu: machine.cpu, memoryMb: request?.memoryMb ?? machine.memoryMB, diskMb: machine.diskMB) ?? (cpu: machine.cpu, memoryMb: machine.memoryMB, diskMb: machine.diskMB) // a chat's folder size raises each axis
        guard let (op, createArgs, options) = CloudStartCore().createParams(name: machine.name, environment: environment, cpu: sized.cpu, memoryMb: sized.memoryMb,
                                                                             diskMb: sized.diskMb, request: request) else { throw Self.rulesUnavailable }
        let args: JSONValue
        if let provider = request?.provider {
            var fields = createArgs.objectValue ?? [:]
            fields["provider"] = .string(provider)
            args = .object(fields)
        } else {
            args = createArgs
        }
        try await validateOptions(options)
        let answer = try await approvalLoop(op, args: args, key: key ?? newKey(), confirmed: true,
                                            approved: key == nil ? nil : approved, onApproved: onApproved,
                                            answering: key == nil ? nil : answering, onAnswering: onAnswering) { _ in true }
        if let room = CloudMachineCap.madeRoom(answer) { madeRoom(room) }
        answered(answer); return answer["machine"] ?? answer
    }

    /// Any other Cloud money or destructive op (`cloud.environment.build`, `.delete`) a person started
    /// in this app: sent once with one key; when the backend holds it for approval, `confirm` asks the
    /// person (a no sends nothing more), then the approval is answered and the same key retried.
    func approvedCall(_ op: String, args: JSONValue, confirm: @MainActor () async -> Bool) async throws -> JSONValue {
        try await approvalLoop(op, args: args, key: newKey(), confirmed: false) { _ in await confirm() }
    }

    /// The first call, then same-key calls for `patience` after the approval (the approved op takes the server a minute
    /// or two): every pass returns, throws, or waits one backoff, all with `key`. `confirmed`: a person already confirmed in this flow.
    /// `approved`: the request an earlier attempt with `key` answered; a pending answer naming it waits
    /// for the approved op (its feed item is closed, so it is not answered again).
    private func approvalLoop(_ op: String, args: JSONValue, key: String, confirmed: Bool, approved earlier: String? = nil,
                              onApproved: @MainActor (String) -> Void = { _ in },
                              answering: String? = nil, onAnswering: @MainActor (String) -> Void = { _ in },
                              ask: @MainActor (_ request: String) async -> Bool) async throws -> JSONValue {
        let ensure = self.beside, origin = now()
        let nowMs = { [now] in Int((now() - origin) / .milliseconds(1)) }
        async let besideDone: Void = ensure()
        var approval = CloudLaunchApproval(), answer: JSONValue?, carried: JSONValue?, lastRunError: String?
        var effects = approval.next(.start(confirmed: confirmed, earlier: earlier, patienceMs: Int(patience / .milliseconds(1)), nowMs: nowMs())) ?? []
        while !effects.isEmpty {
            let event: CloudLaunchApproval.Event
            switch effects.removeFirst() {
            case .call:
                do {
                    answer = try await run(op, args, key, .user); event = .answered
                } catch let failure as CloudAppOpFailure where failure.code == CloudAppOpFailure.approvalPending {
                    lastRunError = failure.lastRunError ?? lastRunError; event = .pending(request: failure.approvalRequest, nowMs: nowMs())
                }
            case .done:
                await besideDone
                guard let answer else { throw Self.rulesUnavailable }
                return answer
            case .ask(let request): event = .asked(yes: await ask(request))
            case .approve(let request):
                onAnswering(request)
                var outcome = "done"
                let steps = Self.steps() // a measured start's `machine.ensure` and `machine.approve`
                var runAnswer: JSONValue?
                do {
                    await besideDone; steps?.done("machine.ensure")
                    defer { steps?.done("machine.approve") }; runAnswer = try await approve(request, op, args)
                } catch let failure as CloudApprovalAnswer.Failure
                            where failure.alreadyAnswered(request: request, answeredEarlier: request == answering) {
                    // An earlier attempt answered it and was cancelled before it could record that: the
                    // item is closed, so wait for the approved op like any answered request.
                    outcome = "already_answered"
                } catch let failure as CloudApprovalAnswer.Failure where failure.answeredElsewhere(request: request) {
                    // Answered elsewhere (the feed on a phone, the dashboard) before this Mac could: nothing
                    // was answered here, so it is not recorded; the bounded same-key retries read the op's answer.
                    outcome = "answered_elsewhere"
                }
                carried = runAnswer
                event = .approved(outcome: outcome, nowMs: nowMs())
            case .recordApproved(let request):
                onApproved(request)
                if let carried { return carried } // carried by the one-call approve; else the next call is the first same-key retry
                continue
            case .pause(let attempt): try await pause(attempt); event = .paused
            case .declined: throw Failure.declined
            case .noApprovalRequest: throw Failure.noApprovalRequest
            case .stillPending(let request): throw Failure.stillPending(request: request, lastRunError: lastRunError)
            }
            guard let next = approval.next(event) else { throw Self.rulesUnavailable }
            effects = next
        }
        throw Self.rulesUnavailable
    }

    /// The app FFI did not answer: nothing more is sent.
    private static var rulesUnavailable: CloudAppOpFailure { CloudAppOpFailure(code: "cmux.cloud.rules_unavailable", message: "") }

    /// 250 ms, 500 ms, then 1 s between the same-key calls after the approval (cmux-cloud-start-core `create_flow::backoff_ms`).
    /// A pending call costs about 200 ms, and an op the server finishes while the flow waits is only seen at the next call.
    static func backoff(_ attempt: Int) -> Duration { CloudStartCore().launchBackoff(attempt) }

    /// The clock that marks the approval's parts of a measured start's `machine` step (``CloudStartSteps``): the wait
    /// for the create's `user.ensure`, then the approval's answer (its reads and `feed.answer`). None outside a start.
    @MainActor static func steps() -> CloudStartSteps? {
        CloudStartStepRecord.current == nil ? nil : CloudStartSteps(logger: stepLogger)
    }

    private static let stepLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.cloud")
}

extension CloudMachineCreateFlow.Failure: CustomStringConvertible, LocalizedError {
    nonisolated var errorDescription: String? { if case .declined = self { nil } else { description } } // what a person reads (`PlainErrorText.personal`)
    nonisolated var description: String {
        switch self {
        case .declined: "declined"
        case .stillPending(_, let why): why.map { "\(CloudStrings.createStillPending) (\($0))" } ?? CloudStrings.createStillPending
        case .noApprovalRequest: CloudStrings.createApproveInFeed
        case .upgradeRequired: CloudStrings.upgradeRequired
        }
    }
}
