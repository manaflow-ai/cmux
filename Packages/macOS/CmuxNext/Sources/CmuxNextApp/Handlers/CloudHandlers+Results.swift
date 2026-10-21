import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon

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
    static func answer(_ label: String, _ invocation: ActionInvocation, _ context: AppActionContext,
                       _ work: @escaping @MainActor () async throws -> CloudAnswer) {
        guard invocation.origin != .user else {
            return runTracked(label, context) {
                let answer = try await work()
                CloudPresenter.show(answer.title, answer.text, copyable: answer.copyable, in: window(context))
            }
        }
        result(label, context) {
            let answer = try await work()
            return answer.fields.merging(["text": .string(answer.text)]) { field, _ in field }
        }
    }

    /// Runs Cloud work that produces `action.run`'s `result` fields, and shows
    /// nothing. A refusal (``ActionFailure``) reaches the caller as one.
    static func result(_ label: String, _ context: AppActionContext,
                       _ work: @escaping @MainActor () async throws -> [String: ActionResultValue]) {
        let logger = context.services.cloud.logger
        // task-owner: the action run; a capturing caller awaits it through the registry.
        let task: ActionResultWork = Task { @MainActor in
            do {
                return .success(try await work())
            } catch let failure as ActionFailure {
                return .failure(ActionWorkFailure(refusal: failure.isNotFound ? .notFound : .unavailable, reason: failure.message))
            } catch {
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return .failure(ActionWorkFailure("\(label): \(error)"))
            }
        }
        context.services.registry.track(result: task)
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
            switch settled {
            case .created?, .pending?, nil:
                guard let session = creation.session else {
                    return .success(["pending": .bool(true), "status": .string("creating"), "creation_id": .string(creation.id.uuidString.lowercased())])
                }
                return .success(createdMachineFields(session, workspaceID: creation.workspaceID))
            case .failed(let reason)?:
                return .failure(ActionWorkFailure("new Cloud machine: \(reason)"))
            case .gone?:
                // Declined in the confirmation (an agent's create asks the person first), or dismissed.
                return .failure(ActionWorkFailure(refusal: .unavailable, reason: CloudStrings.createDeclined))
            }
        }
        registry.track(result: task)
    }

    /// How long `cloud new-machine` waits for the server's machine before it
    /// answers `pending`: inside `action.run`'s 40 s result deadline.
    static let createdMachineWait: Duration = .seconds(30)

    /// The creation's first state that is not `pending`.
    private static func settledCreation(_ creation: CloudMachineCreation, in creations: CloudCreations) async -> CreatedMachine? {
        for await state in ObservationStream({ CreatedMachine(creation, in: creations) }) where state != .pending { return state }
        return nil
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
