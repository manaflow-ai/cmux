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
///    `approval.pending {request}`. The flow shows the native confirmation
///    if no person clicked in this flow yet; on the click it answers that
///    exact request as the person's session (`feed.answer`), then retries
///    with the SAME key until the op's answer arrives (bounded; the
///    approved op runs in the backend after the answer).
///
/// The flow never answers an approval without a native confirmation click
/// in this flow, and a declined confirmation sends nothing more.
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
        /// The plan cannot create a machine: one upgrade card, never a create confirm.
        case upgrade(Upgrade)
    }

    /// Why a create needs a plan upgrade.
    struct Upgrade: Equatable, Sendable {
        typealias Reason = CloudUpgradeReason
        var reason: Reason
    }

    /// Whether the plan lets a create go out.
    enum Gate: Equatable { case allowed, upgrade(Upgrade) }

    /// The plan gate from the last known limits; unknown limits leave the decision to the server.
    static func gate(_ limits: CloudMachineLimits?) -> Gate {
        guard let limits else { return .allowed }
        if limits.maxActiveVms == 0 || limits.planId?.lowercased() == "free" { return .upgrade(Upgrade(reason: .freePlan)) }
        if let max = limits.maxActiveVms, limits.activeVmCount >= max { return .upgrade(Upgrade(reason: .atLimit(max))) }
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
        /// The plan cannot create a machine; nothing was created. A person's create showed the upgrade card
        /// (for `reason`); an agent's shows none and reports the refusal.
        case upgradeRequired(CloudUpgradeReason)
    }

    var run: CloudAppOp
    /// The native confirmation sheet; true only for a person's click.
    var confirm: @MainActor (Prompt) async -> Bool
    /// Answers approval `request` as the person's own session, only when
    /// it holds `cloud.machine.create` with exactly `params`.
    var approve: @MainActor (_ request: String, _ params: JSONValue) async throws -> Void
    /// Waits before the next same-key retry after the approval (cancellable).
    var pause: @MainActor (_ attempt: Int) async throws -> Void
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
    func create(name: String?, startedByPerson: Bool, askedBy: String? = nil, gate: Gate = .allowed) async throws -> JSONValue {
        if case .upgrade(let need) = gate {
            if startedByPerson { _ = await confirm(.upgrade(need)) }
            throw Failure.upgradeRequired(need.reason)
        }
        let machine = Self.named(name, askedBy: askedBy)
        var confirmed = !startedByPerson
        if confirmed { guard await confirm(.agentRequest(machine)) else { throw Failure.declined } }
        var args: [String: JSONValue] = ["size": .object(["cpu": .number(Double(machine.cpu)), "memory_mb": .number(Double(machine.memoryMB)), "disk_mb": .number(Double(machine.diskMB))])]
        if let name = machine.name { args["name"] = .string(name) }
        let key = newKey()
        var approved: String?
        var attempt = 0
        // The first call, then at most `retries` same-key calls after the
        // approval: every pass returns, throws, or counts one retry.
        for _ in 0...max(retries, 0) {
            do {
                let answer = try await run("cloud.machine.create", .object(args), key, .user)
                return answer["machine"] ?? answer
            } catch let failure as CloudAppOpFailure where failure.code == CloudAppOpFailure.approvalPending {
                guard let request = failure.approvalRequest else { throw Failure.noApprovalRequest }
                if let approved {
                    // The answer is in; the approved op runs in the backend.
                    guard approved == request, attempt < retries else { throw Failure.stillPending(request: request) }
                    try await pause(attempt)
                    attempt += 1
                    continue
                }
                if !confirmed {
                    guard await confirm(.approval(request: request, machine)) else { throw Failure.declined }
                    confirmed = true
                }
                try await approve(request, .object(args))
                approved = request
                // The call right after the answer is the first same-key retry.
                attempt = 1
            }
        }
        throw Failure.stillPending(request: approved ?? "")
    }

    /// The legacy `/api/vm` create (the default link). A plan that cannot create (`gate`, or the
    /// server's 402) shows one upgrade card and sends nothing. Otherwise a create no person started
    /// goes out at once; only the opt-in `askFirst` ("ask before creating", default off) asks first,
    /// and a no sends nothing. The plan picks its size, so none shows.
    static func legacy<T>(name: String?, startedByPerson: Bool, askedBy: String? = nil, askFirst: Bool = false, gate: @MainActor () -> Gate = { .allowed },
                          confirm: @MainActor (Prompt) async -> Bool, create: @MainActor () async throws -> T) async throws -> T {
        if case .upgrade(let need) = gate() {
            // The upgrade card is for the person who asked for the machine; an agent's refused create
            // only fails with the refusal, so the person is not prompted on every agent request.
            if startedByPerson { _ = await confirm(.upgrade(need)) }
            throw Failure.upgradeRequired(need.reason)
        }
        if !startedByPerson, askFirst { guard await confirm(.agentRequest(named(name, sizeShown: false, askedBy: askedBy))) else { throw Failure.declined } }
        do {
            return try await create()
        } catch CloudAPIError.http(let status, _, _, _, _) where status == 402 {
            _ = await confirm(.upgrade(Upgrade(reason: .server)))
            throw Failure.upgradeRequired(.server)
        }
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
