internal import Foundation

extension ControlCommandCoordinator {
    /// Dispatches the `orchestration.*` methods this coordinator owns.
    func handleOrchestration(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "orchestration.list":
            return orchestrationList()
        case "orchestration.info":
            return orchestrationInfo(request.params)
        case "orchestration.plan":
            return orchestrationPlan(request.params)
        case "orchestration.run":
            return orchestrationRun(request.params)
        default:
            return nil
        }
    }

    private func orchestrationList() -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "Orchestration context not available", data: nil)
        }
        switch context.controlOrchestrationList() {
        case .resolved(let summaries):
            return .ok(.object([
                "orchestrations": .array(summaries.map(summaryPayload)),
            ]))
        case .failed(let message):
            return .err(code: "internal_error", message: message, data: nil)
        }
    }

    private func orchestrationInfo(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let name = string(params, "name") else {
            return .err(code: "invalid_params", message: "Missing or blank name", data: nil)
        }
        guard let context else {
            return .err(code: "unavailable", message: "Orchestration context not available", data: nil)
        }
        switch context.controlOrchestrationInfo(name: name) {
        case .notInstalled:
            return .err(code: "not_found", message: "Orchestration not installed", data: .object(["name": .string(name)]))
        case .resolved(let summary, let detail):
            var payload = summaryPayload(summary)
            if case .object(var object) = payload, case .object(let detailObject) = detail {
                for (key, value) in detailObject {
                    object[key] = value
                }
                payload = .object(object)
            }
            return .ok(payload)
        case .failed(let message):
            return .err(code: "internal_error", message: message, data: nil)
        }
    }

    private func orchestrationPlan(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "Orchestration context not available", data: nil)
        }
        switch orchestrationRunInputs(params) {
        case .failure(let result):
            return result
        case .success(let inputs):
            switch context.controlOrchestrationPlan(inputs: inputs) {
            case .notInstalled:
                return .err(code: "not_found", message: "Orchestration not installed", data: .object(["name": .string(inputs.name)]))
            case .planFailed(let message):
                return .err(code: "invalid_params", message: message, data: nil)
            case .resolved(let plan, let trustConfirmed, let trustFingerprint):
                return .ok(.object([
                    "plan": plan,
                    "trust_confirmed": .bool(trustConfirmed),
                    "trust_fingerprint": .string(trustFingerprint),
                ]))
            case .failed(let message):
                return .err(code: "internal_error", message: message, data: nil)
            }
        }
    }

    private func orchestrationRun(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "Orchestration context not available", data: nil)
        }
        switch orchestrationRunInputs(params) {
        case .failure(let result):
            return result
        case .success(let inputs):
            let resolution = context.controlOrchestrationRun(
                routing: routingSelectors(params),
                inputs: inputs,
                confirmTrust: bool(params, "confirm_trust") ?? false,
                confirmFingerprint: string(params, "confirm_fingerprint")
            )
            switch resolution {
            case .notInstalled:
                return .err(code: "not_found", message: "Orchestration not installed", data: .object(["name": .string(inputs.name)]))
            case .planFailed(let message):
                return .err(code: "invalid_params", message: message, data: nil)
            case .needsTrustConfirmation(let trust):
                return .err(
                    code: "needs_confirmation",
                    message: "Confirm this template's scripts, agent commands, and substrate before running",
                    data: .object(["trust": trust])
                )
            case .started(let payload):
                return .ok(payload)
            case .failed(let message):
                return .err(code: "internal_error", message: message, data: nil)
            }
        }
    }

    // MARK: - Shared parsing

    /// Parse outcome for the shared plan/run inputs (`Result` requires an
    /// `Error` failure type, which `ControlCallResult` deliberately is not).
    private enum ParsedRunInputs {
        case success(ControlOrchestrationRunInputs)
        case failure(ControlCallResult)
    }

    private func orchestrationRunInputs(
        _ params: [String: JSONValue]
    ) -> ParsedRunInputs {
        guard let name = string(params, "name") else {
            return .failure(.err(code: "invalid_params", message: "Missing or blank name", data: nil))
        }
        var tasks: [ControlOrchestrationTaskInput] = []
        if case .array(let rawTasks)? = params["tasks"] {
            for rawTask in rawTasks {
                switch rawTask {
                case .string(let title):
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    tasks.append(ControlOrchestrationTaskInput(title: trimmed, body: nil, issueNumber: nil))
                case .object(let object):
                    guard case .string(let title)? = object["title"],
                          !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        return .failure(.err(code: "invalid_params", message: "Each task needs a non-empty title", data: nil))
                    }
                    var body: String?
                    if case .string(let rawBody)? = object["body"] {
                        body = rawBody
                    }
                    var issueNumber: Int?
                    if case .int(let rawIssue)? = object["issue_number"] {
                        issueNumber = Int(rawIssue)
                    }
                    tasks.append(ControlOrchestrationTaskInput(
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        body: body,
                        issueNumber: issueNumber
                    ))
                default:
                    return .failure(.err(code: "invalid_params", message: "tasks must be strings or objects", data: nil))
                }
            }
        } else if hasNonNull(params, "tasks") {
            return .failure(.err(code: "invalid_params", message: "tasks must be an array", data: nil))
        }
        var overrides: [String: String] = [:]
        if case .object(let rawParams)? = params["params"] {
            for (key, value) in rawParams {
                switch value {
                case .string(let string): overrides[key] = string
                case .int(let int): overrides[key] = String(int)
                case .bool(let bool): overrides[key] = bool ? "true" : "false"
                case .double(let double): overrides[key] = String(double)
                default:
                    return .failure(.err(code: "invalid_params", message: "params values must be scalars", data: nil))
                }
            }
        } else if hasNonNull(params, "params") {
            return .failure(.err(code: "invalid_params", message: "params must be an object", data: nil))
        }
        return .success(ControlOrchestrationRunInputs(
            name: name,
            tasks: tasks,
            parameterOverrides: overrides,
            agentID: string(params, "agent")
        ))
    }

    private func summaryPayload(_ summary: ControlOrchestrationSummary) -> JSONValue {
        .object([
            "name": .string(summary.name),
            "version": .string(summary.version),
            "description": .string(summary.description),
            "substrate": .string(summary.substrate),
            "agents": .array(summary.agentIDs.map { .string($0) }),
            "source": .string(summary.sourceDisplay),
            "trust_confirmed": .bool(summary.trustConfirmed),
            "unanswered_parameters": .array(summary.unansweredParameterKeys.map { .string($0) }),
        ])
    }
}
