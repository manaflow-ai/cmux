import CmuxNextCloud
import CmuxNextDaemon
import Foundation

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
        guard let limits else { return .allowed }
        if limits.maxActiveVms == 0 || limits.planId?.lowercased() == "free" { return .upgrade(Upgrade(reason: .freePlan)) }
        if let max = limits.maxActiveVms, limits.activeVmCount >= max, !makesRoom { return .upgrade(Upgrade(reason: .atLimit(max))) }
        return .allowed
    }

    // app-type-allow: an existing enum that gains one case (upgradeRequired)
    enum Failure: Error, Equatable {
        /// The person declined the confirmation; nothing was created.
        case declined
        /// The approval was answered, and the backend still held the create
        /// after every retry; the request stays in the feed.
        case stillPending(request: String)
        /// A pending answer without its request id (a protocol break).
        case noApprovalRequest
        /// The plan cannot create a machine; nothing was created. A person's create then shows the cap card
        /// (``CloudService/createMachine``, ``CloudMachineCap``); an agent's shows none and reports the refusal.
        case upgradeRequired(CloudUpgradeReason)
    }

    var run: CloudAppOp
    /// The native confirmation sheet; true only for a person's click.
    var confirm: @MainActor (Prompt) async -> Bool
    /// Answers approval `request` as the person's own session, only when
    /// it holds `op` (the op this flow sent) with exactly `params`.
    var approve: @MainActor (_ request: String, _ op: String, _ params: JSONValue) async throws -> Void
    /// Waits before the next same-key retry after the approval (cancellable).
    var pause: @MainActor (_ attempt: Int) async throws -> Void
    /// Rust checks the selected backend's capabilities before an option-bearing create is sent.
    var validateOptions: @MainActor (_ params: JSONValue) async throws -> Void = { _ in }
    var newKey: () -> String = { UUID().uuidString }
    /// Same-key calls after the approval before ``Failure/stillPending``.
    var retries = 8

    /// The default machine named `name` (trimmed; empty is none), in the stub plan's smallest
    /// size (the backend checks the plan); `sizeShown` false when the plan picks the size.
    static func named(_ name: String?, sizeShown: Bool = true, askedBy: String? = nil) -> Machine {
        Machine(name: name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }, cpu: 2, memoryMB: 4096, diskMB: 16384, sizeShown: sizeShown, askedBy: askedBy)
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
    /// `madeRoom` hears the machine the server paused to make room at the cap (``CloudMachineCap/madeRoom(_:)``).
    func create(name: String?, startedByPerson: Bool, asksFirst: Bool = true, askedBy: String? = nil, key: String? = nil, approved: String? = nil,
                onApproved: @MainActor (String) -> Void = { _ in }, answering: String? = nil, onAnswering: @MainActor (String) -> Void = { _ in },
                gate: Gate = .allowed, environment: String? = nil, request: CloudMachineRequest? = nil,
                madeRoom: @MainActor (JSONValue) -> Void = { _ in }) async throws -> JSONValue {
        if case .upgrade(let need) = gate { throw Failure.upgradeRequired(need.reason) }
        let machine = Self.named(name, askedBy: askedBy)
        // A person's own gesture is the confirmation, so the backend's hold gets no second prompt.
        if !startedByPerson, asksFirst { guard await confirm(.agentRequest(machine)) else { throw Failure.declined } }
        let requestedMemory = request?.memoryMb ?? machine.memoryMB
        var args: [String: JSONValue] = ["size": .object(["cpu": .number(Double(machine.cpu)), "memory_mb": .number(Double(requestedMemory)), "disk_mb": .number(Double(machine.diskMB))])]
        if let name = machine.name { args["name"] = .string(name) }
        // These are deliberately sent through the typed op boundary. Backends that do not
        // advertise the option must reject it; the client never silently drops a request.
        if let request {
            if let size = request.size { args["size_name"] = .string(size) }
            if request.persistent { args["idle_seconds"] = .number(0) }
            if let script = request.script {
                args["bootstrap"] = .object([
                    "kind": .string(script.kind.rawValue),
                    "contents_base64": .string(script.contents.base64EncodedString()),
                    "repo": script.repo.map { .string($0.spec) } ?? .null,
                ])
            }
            if let config = request.machineConfig {
                args["machine_config_base64"] = .string(config.contents?.base64EncodedString() ?? "")
            }
        }
        if let environment { args["environment"] = .string(environment) }
        try await validateOptions(.object(args))
        let op = environment == nil ? "cloud.machine.create" : "cloud.environment.boot"
        let answer = try await approvalLoop(op, args: .object(args), key: key ?? newKey(), confirmed: true,
                                            approved: key == nil ? nil : approved, onApproved: onApproved,
                                            answering: key == nil ? nil : answering, onAnswering: onAnswering) { _ in true }
        if let room = CloudMachineCap.madeRoom(answer) { madeRoom(room) }
        return answer["machine"] ?? answer
    }

    /// Any other Cloud money or destructive op (`cloud.environment.build`, `.delete`) a person started
    /// in this app: sent once with one key; when the backend holds it for approval, `confirm` asks the
    /// person (a no sends nothing more), then the approval is answered and the same key retried.
    func approvedCall(_ op: String, args: JSONValue, confirm: @MainActor () async -> Bool) async throws -> JSONValue {
        try await approvalLoop(op, args: args, key: newKey(), confirmed: false) { _ in await confirm() }
    }

    /// The first call, then at most `retries` same-key calls after the approval: every pass
    /// returns, throws, or counts one retry, all with `key`. `confirmed`: a person already confirmed in this flow.
    /// `approved`: the request an earlier attempt with `key` answered; a pending answer naming it waits
    /// for the approved op (its feed item is closed, so it is not answered again).
    private func approvalLoop(_ op: String, args: JSONValue, key: String, confirmed: Bool, approved earlier: String? = nil,
                              onApproved: @MainActor (String) -> Void = { _ in },
                              answering: String? = nil, onAnswering: @MainActor (String) -> Void = { _ in },
                              ask: @MainActor (_ request: String) async -> Bool) async throws -> JSONValue {
        var confirmed = confirmed
        var approved: String?
        var attempt = 0
        for _ in 0...max(retries, 0) {
            do {
                return try await run(op, args, key, .user)
            } catch let failure as CloudAppOpFailure where failure.code == CloudAppOpFailure.approvalPending {
                guard let request = failure.approvalRequest else { throw Failure.noApprovalRequest }
                if approved == nil, request == earlier { approved = request }
                if let approved {
                    // The answer is in; the approved op runs in the backend.
                    guard approved == request, attempt < retries else { throw Failure.stillPending(request: request) }
                    try await pause(attempt)
                    attempt += 1
                    continue
                }
                if !confirmed {
                    guard await ask(request) else { throw Failure.declined }
                    confirmed = true
                }
                onAnswering(request)
                do {
                    try await approve(request, op, args)
                } catch let failure as CloudApprovalAnswer.Failure
                            where failure.alreadyAnswered(request: request, answeredEarlier: request == answering) {
                    // An earlier attempt answered it and was cancelled before it could record that: the
                    // item is closed, so wait for the approved op like any answered request.
                } catch let failure as CloudApprovalAnswer.Failure where failure.answeredElsewhere(request: request) {
                    // Answered elsewhere (the feed on a phone, the dashboard) before this Mac could: nothing
                    // was answered here, so it is not recorded; the bounded same-key retries read the op's answer.
                    approved = request
                    attempt = 1
                    continue
                }
                approved = request
                onApproved(request)
                // The call right after the answer is the first same-key retry.
                attempt = 1
            }
        }
        throw Failure.stillPending(request: approved ?? "")
    }

    /// 1, 2, 4 … 8 s between the same-key retries after the approval.
    static func backoff(_ attempt: Int) -> Duration { .seconds(min(8, 1 << min(max(attempt - 1, 0), 3))) }
}

extension CloudMachineCreateFlow.Failure: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .declined: "declined"
        case .stillPending: CloudStrings.createStillPending
        case .noApprovalRequest: CloudStrings.createApproveInFeed
        case .upgradeRequired: CloudStrings.upgradeRequired
        }
    }
}
