import AppKit
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// The Cloud app server path of the machine list and create (cx-t2rz):
/// `cloud.machine.list` / `cloud.machine.create` on `cmux/cloud`, which
/// reaches the cmux-next API Worker through the host credential relay.
extension CloudService {
    /// Every page of `cloud.machine.list` (a read: no key, origin script).
    func appServerMachines() async throws -> [CloudMachine] {
        var machines: [CloudMachine] = []
        var cursor: String?
        // At most 50 pages of 100: a list that never ends is a server bug.
        for _ in 0..<50 {
            var args: [String: JSONValue] = ["limit": .number(100)]
            if let cursor { args["cursor"] = .string(cursor) }
            let page = try await appOps("cloud.machine.list", .object(args), nil, .script)
            machines += (page["machines"]?.arrayValue ?? []).compactMap(CloudMachine.init(next:))
            guard let next = page["next_cursor"]?.stringValue, !next.isEmpty else { return machines }
            cursor = next
        }
        return machines
    }

    /// One `cloud.machine.create` through ``CloudMachineCreateFlow``.
    func appServerCreate(name: String?, startedByPerson: Bool) async throws -> CloudMachine {
        let approvals = CloudApprovalAnswer(call: sessionCall())
        let flow = CloudMachineCreateFlow(
            run: appOps,
            confirm: { [weak self] prompt in await CloudPresenter.confirmCreate(prompt, in: self?.confirmWindow?()) },
            approve: { request in try await approvals.approve(request: request) },
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

    /// POSTs to the API Worker as the signed-in person (Stack session), the
    /// way the feed does; used only to answer a G8 approval after the
    /// person's native confirmation. Never on the relay path.
    private func sessionCall() -> CloudApprovalAnswer.Call {
        let base = FeedService.apiBaseURL(auth: auth)
        let auth = auth
        return { path, body in
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(try await auth.tokens().access)", forHTTPHeaderField: "authorization")
            request.httpBody = body
            return try await URLSession.shared.data(for: request).0
        }
    }
}

extension CloudPresenter {
    /// The native confirmation of a Cloud machine create: true only for the
    /// person's click on Create; no window answers false.
    @MainActor static func confirmCreate(_ prompt: CloudMachineCreateFlow.Prompt, in window: NSWindow?) async -> Bool {
        let body = switch prompt {
        case .agentRequest: CloudStrings.createConfirmAgent
        case .approval: CloudStrings.createConfirmApproval
        }
        return await withCheckedContinuation { continuation in
            confirm(CloudStrings.createConfirmTitle, body, button: CloudStrings.createConfirmButton,
                    identifier: createConfirmIdentifier, in: window) { continuation.resume(returning: $0) }
        }
    }
}
