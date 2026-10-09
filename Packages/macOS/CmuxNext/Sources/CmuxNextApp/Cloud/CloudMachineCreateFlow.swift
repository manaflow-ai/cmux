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
    enum Prompt: Equatable {
        /// A create that no person started asks first.
        case agentRequest
        /// The backend holds the create for the person's approval.
        case approval(request: String)
    }

    enum Failure: Error, Equatable {
        /// The person declined the confirmation; nothing was created.
        case declined
        /// The approval was answered, and the backend still held the create
        /// after every retry; the request stays in the feed.
        case stillPending(request: String)
        /// A pending answer without its request id (a protocol break).
        case noApprovalRequest
    }

    var run: CloudAppOp
    /// The native confirmation sheet; true only for a person's click.
    var confirm: @MainActor (Prompt) async -> Bool
    /// Answers approval `request` as the person's own session.
    var approve: @MainActor (_ request: String) async throws -> Void
    /// Waits before the next same-key retry after the approval (cancellable).
    var pause: @MainActor (_ attempt: Int) async throws -> Void
    var newKey: () -> String = { UUID().uuidString }
    /// Same-key retries after the approval before ``Failure/stillPending``.
    var retries = 8

    /// The default machine size (the stub plan's smallest; the backend
    /// checks the plan).
    static let defaultSize: JSONValue = .object(["cpu": .number(2), "memory_mb": .number(4096), "disk_mb": .number(16384)])

    /// Creates a machine; `startedByPerson` is true for the person's own
    /// gesture in this app (click, menu, palette, key). Returns the machine
    /// record (contract 1.2).
    func create(name: String?, startedByPerson: Bool) async throws -> JSONValue {
        // red: no confirmation, no approval handling
        var args: [String: JSONValue] = ["size": Self.defaultSize]
        if let name, !name.isEmpty { args["name"] = .string(name) }
        let answer = try await run("cloud.machine.create", .object(args), newKey(), .user)
        return answer["machine"] ?? answer
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
        }
    }
}
