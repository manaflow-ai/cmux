import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextSidebar
import Foundation

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
        let inner: ActionResultWork = Task { @MainActor in
            do {
                return .success(try await work())
            } catch let failure as ActionFailure {
                if !captured { CloudPresenter.failure(failure, in: window(context)) }
                return .failure(ActionWorkFailure(refusal: failure.isNotFound ? .notFound : .unavailable, reason: failure.message))
            } catch {
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if !captured { CloudPresenter.failure(error, in: window(context)) }
                return .failure(ActionWorkFailure(log: "\(label): \(CloudStrings.errorText(error))", reason: CloudStrings.errorText(error)))
            }
        }
        guard let pendingAfter else { return context.services.registry.track(result: inner) }
        // task-owner: the action run's answer: the work's, or `pending` once the wait ends.
        let task: ActionResultWork = Task { @MainActor in
            await firstAnswer(inner, within: pendingAfter) ?? .success(pending.merging(["pending": .bool(true)]) { field, _ in field })
        }
        context.services.registry.track(result: task)
    }

    /// `work`'s answer if it comes within `wait`, else nil (the work keeps
    /// running). Both sides yield into one stream and the first value wins:
    /// awaiting an unstructured task's `value` ignores cancellation, so a
    /// task group racing it would wait for the work to end anyway. The stream
    /// keeps only the first of its two values.
    static func firstAnswer(_ work: ActionResultWork, within wait: Duration) async -> Result<[String: ActionResultValue], ActionWorkFailure>? {
        let (answers, continuation) = AsyncStream<Result<[String: ActionResultValue], ActionWorkFailure>?>
            .makeStream(bufferingPolicy: .bufferingOldest(1))
        // task-owner: relays the work's answer; it ends with the work (a yield after finish is dropped).
        Task { continuation.yield(await work.value) }
        // task-owner: the answer deadline; cancelled below once an answer is in.
        let deadline = Task {
            // wakeup-allow: one-shot answer deadline; cancelled when the work answers first
            try? await Task.sleep(for: wait)
            continuation.yield(nil)
        }
        defer {
            deadline.cancel()
            continuation.finish()
        }
        for await answer in answers { return answer }
        return nil
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
        // task-owner: the action run; it ends when the create settles or the wait ends.
        let task: ActionResultWork = Task { @MainActor in
            // concurrency-allow: the observation task is cancelled by the bounded race below
            let settled = await withTaskGroup(of: CreatedMachine?.self) { group -> CreatedMachine? in
                group.addTask { await settledCreation(creation, in: creations) }
                group.addTask {
                    // wakeup-allow: one-shot answer deadline; this task is cancelled when the create settles first
                    try? await Task.sleep(for: wait)
                    return nil
                }
                defer { group.cancelAll() }
                return await group.next() ?? nil
            }
            // A refusal a paid plan lifts answers `cloud.plan.required` and names the plan, so a CLI or
            // agent caller can start that plan's checkout; a declined or dismissed create is refused.
            var facts: [String: Any] = ["creationId": creation.id.uuidString.lowercased(), "workspaceId": creation.workspaceID as Any,
                                        "plan": creation.planRefusal?.plan as Any, "machine": creation.session.map(machineFacts) as Any]
            switch settled {
            case .pending?, nil: break
            case .created?: facts["state"] = "created"
            case .gone?: facts["state"] = "gone"
            case .failed(let reason)?:
                facts["state"] = "failed"
                facts["reason"] = reason
            }
            let reply = CloudHandlerRules().ask("cloud_handler_settled", facts.compacted)
            if let failure = reply?["failure"] as? [String: Any] {
                let reason = CloudHandlerRules.text(CloudHandlerRules.decodeSaid(failure["reason"] ?? NSNull()))
                if failure["refusal"] as? Bool == true { return .failure(ActionWorkFailure(refusal: .unavailable, reason: reason)) }
                if let code = failure["code"] as? String { return .failure(ActionWorkFailure(code: code, reason: reason)) }
                return .failure(ActionWorkFailure(reason))
            }
            guard case .object(let fields)? = reply?["fields"].map(CloudHandlerRules.result) else {
                return .failure(ActionWorkFailure(refusal: .unavailable, reason: CloudStrings.createDeclined))
            }
            return .success(fields)
        }
        registry.track(result: task)
    }

    /// How long `cloud new-machine` waits for the server's machine before it
    /// answers `pending`: inside `action.run`'s 40 s result deadline.
    static let createdMachineWait: Duration = .seconds(30)

    /// The creation's first state that is not `pending`.
    static func settledCreation(_ creation: CloudMachineCreation, in creations: CloudCreations) async -> CreatedMachine? {
        for await state in ObservationStream({ CreatedMachine(creation, in: creations) }) where state != .pending { return state }
        return nil
    }

    /// A machine's facts for the rules (``CloudHandlerRules``): its id, title, shown status, size and address.
    static func machineFacts(_ session: CloudMachineSession) -> [String: Any] {
        let machine = session.machine
        return ["id": session.machineID, "title": machine.title, "status": session.effectiveStatus.rawValue,
                "displayName": machine.displayName as Any, "sizeName": machine.size?.name as Any, "cpu": machine.size?.cpu as Any,
                "memoryMb": machine.size?.memoryMb as Any, "idlePauseMinutes": machine.idlePauseMinutes as Any,
                "ipv4": machine.address?.ipv4 as Any, "ipv6": machine.address?.ipv6 as Any].compacted
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
        var reason: String?
        if case .failed(let why) = creation.phase { reason = why }
        let state = CloudHandlerRules().ask("cloud_handler_creation", [
            "listed": creations.all.contains(where: { $0 === creation }), "hasSession": creation.session != nil, "failed": reason != nil,
        ])?["state"] as? String
        switch state {
        case "created": self = .created
        case "failed": self = .failed(reason ?? "")
        case "gone": self = .gone
        default: self = .pending
        }
    }
}

/// The app's side of ``CloudHandlerRules``: its words for each refusal key, and the port names.
extension CloudHandlerRules {
    init() {
        self.init(words: { Self.failure($0) })
    }

    /// The refusal when the rules do not answer (the app's FFI is missing an op): the action does nothing.
    static var unanswered: String {
        String(localized: "cloud.operationUnavailable", defaultValue: "This action is unavailable for this Cloud machine.", bundle: .module)
    }

    func arg(_ check: String, _ invocation: ActionInvocation, port names: CloudPortNames? = nil, extra: [String: Any] = [:]) throws -> Any {
        try arg(check, invocation, names: names.map(Self.json), extra: extra)
    }

    func text(_ check: String, _ invocation: ActionInvocation, port names: CloudPortNames? = nil, extra: [String: Any] = [:]) throws -> String {
        try arg(check, invocation, port: names, extra: extra) as? String ?? ""
    }

    func port(_ invocation: ActionInvocation) throws -> Int {
        try arg("port", invocation) as? Int ?? 0
    }

    func namedPort(_ invocation: ActionInvocation, _ names: CloudPortNames, verb: String) throws -> Int {
        try arg("namedPort", invocation, port: names, extra: ["verb": verb]) as? Int ?? 0
    }

    func id(_ invocation: ActionInvocation, missing: String) throws -> String {
        try text("id", invocation, extra: ["missing": missing])
    }

    /// The machine and port a port message names, as the rules read them (`port` absent: `<port>`).
    static func json(_ names: CloudPortNames) -> [String: Any] {
        var object: [String: Any] = ["name": names.name, "id": names.id]
        if let port = Int(names.port) { object["port"] = port }
        return object
    }

    /// `said` as a thrown refusal: not found and bad targets keep their kind.
    static func failure(_ said: Said) -> ActionFailure {
        let message = text(said)
        switch said.kind {
        case "not_found": return .notFound(message)
        case "invalid_target": return .invalidTarget(message)
        default: return ActionFailure(message: message)
        }
    }

    /// The app's localized words for what the rules said. A port refusal names the machine and
    /// port first (name, id, port), then its own values.
    static func text(_ said: Said) -> String {
        let first = said.args.first ?? ""
        let value = { (index: Int) in said.args.indices.contains(index) ? said.args[index] : "" }
        var names = CloudPortNames(name: value(0), id: value(1), port: nil)
        if said.args.count > 2 { names.port = value(2) }
        switch said.key {
        case "text": return first
        case "unavailable": return Self.unanswered
        case "commandRequired": return CloudStrings.commandRequired
        case "filePathRequired": return CloudStrings.filePathRequired
        case "invalidPort": return CloudStrings.invalidPort
        case "idlePauseMustBeOneOf": return CloudStrings.idlePauseMustBeOneOf(first)
        case "machineWorkspaceRequired": return CloudStrings.machineWorkspaceRequired(first)
        case "publicationRequired": return CloudStrings.publicationRequired
        case "publicKeyRequired": return CloudStrings.publicKeyRequired
        case "fileContentsRequired": return CloudStrings.fileContentsRequired
        case "snapshotRequired": return CloudStrings.snapshotRequired
        case "apiKeyRequired": return CloudStrings.apiKeyRequired
        case "machineConfigUnreadable": return CloudStrings.machineConfigUnreadable(first)
        case "sizeMustBeOneOf": return CloudStrings.sizeMustBeOneOf(first)
        case "laneNeedsName": return CloudStrings.laneNeedsName
        case "repoUnrecognized": return CloudStrings.repoUnrecognized
        case "repoCredentialsInURL": return CloudStrings.repoCredentialsInURL
        case "repoInvalidRef": return CloudStrings.repoInvalidRef
        case "resizeNeedsSizeOrDisk": return CloudStrings.resizeNeedsSizeOrDisk(first)
        case "bootstrapScriptRequired": return CloudStrings.bootstrapScriptRequired
        case "machineNameInvalid": return CloudStrings.machineNameInvalid
        case "unknownMachine": return CloudStrings.unknownMachine(first)
        case "noMachine": return CloudStrings.noMachine
        case "createDeclined": return CloudStrings.createDeclined
        case "signInFirst": return CloudStrings.signInFirst
        case "diagnosticsAllWell": return CloudStrings.diagnosticsAllWell(first)
        case "noTeams": return CloudStrings.noTeams
        case "noSuchTeam": return CloudStrings.noSuchTeam(first)
        case "portInvalid": return CloudPortStrings.invalidPort(names, verb: value(2))
        case "portFailed": return CloudPortStrings.failed(names, detail: value(3))
        case "portLimit": return CloudPortStrings.limit(names)
        case "portPathInvalid": return CloudPortStrings.pathInvalid(names)
        case "portNoLink": return CloudPortStrings.noLink(names)
        case "gitHubAppConfirmBody": return CloudStrings.gitHubAppConfirmBody(name: value(0), email: value(1))
        case "gitHubAppConfirmNoIdentity": return CloudStrings.gitHubAppConfirmNoIdentity
        case "gitHubConfirmBody": return CloudStrings.gitHubConfirmBody(name: value(0), email: value(1))
        case "gitHubConfirmNoIdentity": return CloudStrings.gitHubConfirmNoIdentity
        case "gitHubFallbackNotConnected": return CloudStrings.gitHubFallback(.notConnected)
        case "gitHubFallbackNotConfigured": return CloudStrings.gitHubFallback(.notConfigured)
        case "gitHubFallbackUnknown": return CloudStrings.gitHubFallback(.unknown)
        default: return said.args.isEmpty ? Self.unanswered : said.args.joined(separator: " ")
        }
    }
}
