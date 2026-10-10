import AppKit
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDesign
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
    func appServerCreate(name: String?, startedByPerson: Bool, onSent: @escaping @MainActor @Sendable () async -> Void) async throws -> CloudMachine {
        let approvals = CloudApprovalAnswer(call: sessionCall())
        let ops = appOps
        // The team the relay's create bills: the install token's team claim,
        // captured now, when the person starts or confirms this create.
        let team = Self.team(ofToken: try await installIdentity.installToken()) ?? ""
        let flow = CloudMachineCreateFlow(
            run: { op, args, key, origin in
                await onSent()
                return try await ops(op, args, key, origin)
            },
            confirm: { [weak self] prompt in await CloudPresenter.confirmCreate(prompt, in: self?.confirmWindow?()) },
            approve: { request, params in
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

    /// The `team` claim of an install token (the owner's own token over
    /// TLS; read for consistency, never trusted as a credential). Nil when
    /// the token is not a JWT with a team.
    nonisolated static func team(ofToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let team = claims["team"] as? String, !team.isEmpty else { return nil }
        return team
    }

    /// POSTs to the API Worker as the signed-in person (Stack session), the
    /// way the feed does; used only to answer a G8 approval after the
    /// person's native confirmation. Never on the relay path.
    private func sessionCall() -> CloudApprovalAnswer.Call {
        let base = FeedService.apiBaseURL(auth: auth)
        let auth = auth
        let session = Self.sessionTransport
        return { path, body in
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(try await auth.tokens().access)", forHTTPHeaderField: "authorization")
            request.httpBody = body
            return try await session.data(for: request).0
        }
    }

    /// No cache, no cookies, and redirects refused: the Stack bearer never
    /// follows one (as `InstallHTTPTransport`).
    private static let sessionTransport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: CloudRefuseRedirects(), delegateQueue: nil)
    }()
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
                    identifier: createConfirmIdentifier, kind: .money, in: window) { continuation.resume(returning: $0) }
        }
    }
}

/// Answers every redirect with "do not follow" (completion-handler form).
private nonisolated final class CloudRefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
