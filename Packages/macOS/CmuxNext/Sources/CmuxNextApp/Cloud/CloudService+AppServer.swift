import AppKit
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSidebar
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

    /// One `cloud.machine.create` (or `cloud.environment.boot` for `environment`) through ``CloudMachineCreateFlow``.
    func appServerCreate(name: String?, startedByPerson: Bool, askedBy: String?, environment: String? = nil,
                         onSent: @escaping @MainActor @Sendable () async -> Void) async throws -> CloudMachine {
        let flow = try await appServerFlow(onSent: onSent)
        let record = try await flow.create(name: name, startedByPerson: startedByPerson, askedBy: askedBy, gate: createGate, environment: environment)
        guard let machine = CloudMachine(next: record) else { throw CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "the create answered no machine") }
        return machine
    }

    /// A money or destructive Cloud op a person started in this app (`cloud.environment.build`,
    /// `.delete`) through the same approval loop as a create; `confirm` is its native confirmation.
    func appServerApprovedCall(_ op: String, args: JSONValue, confirm: @MainActor () async -> Bool) async throws -> JSONValue {
        try await appServerFlow(onSent: {}).approvedCall(op, args: args, confirm: confirm)
    }

    /// The team's Cloud environments for the New Cloud Workspace dialog; none when the list fails
    /// (the dialog then offers only a new one).
    func appServerEnvironmentOptions() async -> [CloudWorkspaceSetupWizard.EnvironmentOption] {
        guard let answer = try? await appOps("cloud.environment.list", .object([:]), nil, .script) else { return [] }
        return (answer["environments"]?.arrayValue ?? []).compactMap { value in
            guard let id = value["id"]?.stringValue, let name = value["name"]?.stringValue else { return nil }
            return CloudWorkspaceSetupWizard.EnvironmentOption(id: id, name: name)
        }
    }

    /// Saves a new environment (`cloud.environment.set`) for the New Cloud Workspace dialog; its id.
    func appServerSaveEnvironment(_ new: CloudWorkspaceSetupWizard.NewEnvironment) async throws -> String {
        let args: JSONValue = .object(["name": .string(new.name), "repo": .string(new.repo.spec), "setup_script": .string(new.setupScript)])
        let answer = try await appOps("cloud.environment.set", args, UUID().uuidString, .user)
        guard let id = answer["environment"]?["id"]?.stringValue else {
            throw CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "cloud.environment.set answered no environment")
        }
        return id
    }

    /// The approval-aware flow every person-confirmed app-server op runs through.
    private func appServerFlow(onSent: @escaping @MainActor @Sendable () async -> Void) async throws -> CloudMachineCreateFlow {
        let approvals = CloudApprovalAnswer(call: sessionCall())
        let ops = appOps
        // The team the relay's create bills: the install token's team claim,
        // captured now, when the person starts or confirms this create.
        let team = MacInstallIdentity.team(ofToken: try await installIdentity.installToken()) ?? ""
        let flow = CloudMachineCreateFlow(
            run: { op, args, key, origin in
                await onSent()
                return try await ops(op, args, key, origin)
            },
            confirm: { [weak self] prompt in await self?.confirmCreate?(prompt) ?? false },
            approve: { request, op, params in
                try await approvals.approve(request: request, op: op, params: try JSONEncoder().encode(params), team: team)
            },
            pause: { attempt in
                // wakeup-allow: bounded same-key retry of a retryable approval.pending after the person approved (cx-t2rz)
                try await ContinuousClock().sleep(for: CloudMachineCreateFlow.backoff(attempt))
            }
        )
        return flow
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
    /// Confirms a Cloud machine create: true only for the person's click on Create; no window answers
    /// false. An agent's or a script's request waits in the sidebar's card (`asks`), the backend's hold in a sheet.
    /// `chatOpen` says whether an agent chat is still open: a card its asking chat had goes, a no, when the chat closes.
    @MainActor static func confirmCreate(_ prompt: CloudMachineCreateFlow.Prompt, in window: NSWindow?, asks: SidebarAsks?, chatOpen: @escaping @MainActor @Sendable (String) -> Bool = { _ in true },
                                         openPricing: @MainActor (URL) -> Void = { NSWorkspace.shared.openInBackground($0) }) async -> Bool {
        if case .upgrade(let need) = prompt {
            // No window or sidebar to show the card in: nothing is opened without the person's click.
            guard let asks, window != nil else { return false }
            let upgrade = await asks.ask(CloudStrings.upgradeTitle, detail: CloudStrings.upgradeDetail(need.reason), symbol: "cloud", yes: CloudStrings.upgradeButton, no: CloudStrings.notNow)
            if upgrade { openPricing(StaticURL.pricing.url) }
            return upgrade
        }
        let intro: String, machine: CloudMachineCreateFlow.Machine
        switch prompt {
        case .agentRequest(let asked): (intro, machine) = (CloudStrings.createRequestDetail, asked)
        case .approval(_, let held): (intro, machine) = (CloudStrings.createConfirmApproval, held)
        case .upgrade: return false // answered above
        }
        let lines = (machine.name.map { [CloudStrings.createConfirmName($0)] } ?? []) + (machine.sizeShown ? [CloudStrings.createConfirmSize(cpu: machine.cpu, memoryGB: machine.memoryMB / 1024, diskGB: machine.diskMB / 1024)] : [])
        if case .agentRequest = prompt, let asks { return window != nil ? await asks.ask(CloudStrings.createConfirmTitle, detail: intro, lines: lines, symbol: "cloud", yes: CloudStrings.createConfirmButton, no: CloudStrings.cancel, asker: machine.askedBy, present: chatOpen) : false }
        return await withCheckedContinuation { continuation in
            confirm(CloudStrings.createConfirmTitle, ([intro] + lines).joined(separator: "\n"), button: CloudStrings.createConfirmButton,
                    identifier: createConfirmIdentifier, in: window) { continuation.resume(returning: $0) }
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
