import AppKit
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// The Cloud app server path of the machine list and create (cx-t2rz):
/// `cloud.machine.list` / `cloud.machine.create` on `cmux/cloud`, which
/// reaches the cmux-next API Worker through the host credential relay.
extension CloudService {
    /// Every page of `cloud.machine.list` (a read: no key, origin script).
    func appServerMachines(scope: CloudTeamScope.Snapshot) async throws -> [CloudMachine] {
        let ops = appOps(scope)
        var machines: [CloudMachine] = []
        var cursor: String?
        // At most 50 pages of 100: a list that never ends is a server bug.
        for _ in 0..<50 {
            var args: [String: JSONValue] = ["limit": .number(100)]
            if let cursor { args["cursor"] = .string(cursor) }
            let page = try await ops("cloud.machine.list", .object(args), nil, .script)
            machines += (page["machines"]?.arrayValue ?? []).compactMap(CloudMachine.init(next:))
            guard let next = page["next_cursor"]?.stringValue, !next.isEmpty else { return machines }
            cursor = next
        }
        return machines
    }

    /// One `cloud.machine.create` through ``CloudMachineCreateFlow``.
    func appServerCreate(name: String?, startedByPerson: Bool, scope: CloudTeamScope.Snapshot, onSent: @escaping @MainActor @Sendable () async -> Void) async throws -> CloudMachine {
        let approvals = CloudApprovalAnswer(call: scope.call)
        let ops = appOps(scope)
        let team = scope.team
        let flow = CloudMachineCreateFlow(
            run: { op, args, key, origin in
                try await scope.recheck()
                await onSent()
                try await scope.recheck()
                return try await ops(op, args, key, origin)
            },
            confirm: { [weak self] prompt in await CloudPresenter.confirmCreate(prompt, in: self?.confirmWindow?()) },
            approve: { request, params in
                try await scope.recheck()
                try await approvals.approve(request: request, op: "cloud.machine.create", params: try JSONEncoder().encode(params), team: team)
            },
            pause: { attempt in
                // wakeup-allow: bounded same-key retry of a retryable approval.pending after the person approved (cx-t2rz)
                try await ContinuousClock().sleep(for: CloudMachineCreateFlow.backoff(attempt))
            }
        )
        let record = try await flow.create(name: name, startedByPerson: startedByPerson)
        guard let machine = CloudMachine(next: record) else {
            throw CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "cloud.machine.create answered no machine")
        }
        return machine
    }

}

extension CloudPresenter {
    /// The native confirmation of a Cloud machine create: true only for the
    /// person's click on Create; no window answers false.
    @MainActor static func confirmCreate(_ prompt: CloudMachineCreateFlow.Prompt, in window: NSWindow?) async -> Bool {
        let (intro, machine) = switch prompt {
        case .agentRequest(let machine): (CloudStrings.createConfirmAgent, machine)
        case .approval(_, let machine): (CloudStrings.createConfirmApproval, machine)
        }
        var lines = [CloudStrings.createConfirmSize(cpu: machine.cpu, memoryGB: machine.memoryMB / 1024, diskGB: machine.diskMB / 1024)]
        if let name = machine.name { lines.insert(CloudStrings.createConfirmName(name), at: 0) }
        let body = ([intro] + lines).joined(separator: "\n")
        return await withCheckedContinuation { continuation in
            confirm(CloudStrings.createConfirmTitle, body, button: CloudStrings.createConfirmButton,
                    identifier: createConfirmIdentifier, in: window) { continuation.resume(returning: $0) }
        }
    }
}
