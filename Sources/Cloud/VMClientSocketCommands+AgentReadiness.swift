import CmuxCloud
import Foundation

extension TerminalController {
    /// `vm.agent_readiness {id, agent?, probe?, fast?}`: whether each agent CLI on the
    /// machine can start, from ``CloudAgentReadinessService`` (the path the Cloud
    /// Secrets sheet's Agents section uses too). The response carries names, fixed
    /// words, hosts, and HTTP status codes, never a value. `probe` asks each key's own
    /// provider (a constant URL in the script) to accept it; `fast` is `vm agent`'s
    /// pre-launch form, with no network on the machine.
    nonisolated func socketWorkerVMAgentReadinessResponse(id: Any?, params: [String: Any]) -> String {
        let method = "vm.agent_readiness"
        let machine: String
        do {
            machine = try CloudSecretsSocketParams.machineID(params, method: method)
        } catch let failure as CloudSecretsSocketFailure {
            return v2Error(id: id, code: failure.code, message: failure.message)
        } catch {
            return v2Error(id: id, code: "invalid_params", message: method)
        }
        var agent: CloudAgentReadinessAgent?
        if let raw = CloudSecretsSocketParams.string(params["agent"]) {
            guard let parsed = CloudAgentReadinessAgent(argument: raw) else {
                return v2Error(id: id, code: "invalid_params", message: String(
                    format: String(localized: "cloudAgentReadiness.socket.unknownAgent", defaultValue: "%1$@: unknown agent '%2$@' (use %3$@)."),
                    method, raw, CloudAgentReadinessAgent.allCases.map(\.rawValue).joined(separator: ", ")
                ))
            }
            agent = parsed
        }
        let request = CloudAgentReadinessRequest(
            agent: agent,
            probe: CloudSecretsSocketParams.bool(params["probe"]) ?? false,
            fast: CloudSecretsSocketParams.bool(params["fast"]) ?? false
        )
        // How fixes address the machine: the label the caller typed, else the id.
        let address = CloudSecretsSocketParams.string(params["machine_label"]) ?? machine
        let timeoutSeconds = TimeInterval(request.execTimeoutMs / 1000 + (request.fast ? 2 : 15))
        return v2VmCall(id: id, timeoutSeconds: timeoutSeconds) {
            let result = try await CloudAgentReadinessService.live.check(machineID: machine, request: request)
            return Self.agentReadinessPayload(result, address: address)
        }
    }

    nonisolated static func agentReadinessPayload(_ result: CloudAgentReadinessService.Result, address: String) -> [String: Any] {
        let assessments = result.assessments(machine: address)
        func orNull(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
        let agents: [[String: Any]] = assessments.map { assessment in
            let entry = assessment.entry
            var probe: [String: Any] = ["result": "not_run", "status": NSNull()]
            switch entry.probe {
            case .notRun: break
            case .status(let code): probe = ["result": "status", "status": code]
            case .unreachable: probe["result"] = "unreachable"
            case .skipped: probe["result"] = "skipped"
            case .unsupported: probe["result"] = "unsupported"
            }
            return [
                "agent": entry.agent.rawValue,
                "name": CloudAgentReadinessAssessment.displayName(entry.agent),
                "installed": entry.installed,
                "version": orNull(entry.version),
                "source": entry.source.rawValue,
                "key": orNull(entry.keyName),
                "credential": assessment.credential,
                "mode": orNull(entry.mode),
                "reason": orNull(entry.reason),
                "endpoint_kind": entry.endpoint.rawValue,
                "host": orNull(entry.host),
                "endpoint": assessment.endpoint,
                "git_credential_helper": entry.gitCredentialHelper.map { $0 as Any } ?? NSNull(),
                "probe": probe,
                "status": assessment.status.rawValue,
                "status_label": assessment.statusLabel,
                "detail": assessment.detail,
                "fix": orNull(assessment.fix),
                "warning": orNull(assessment.preLaunchWarning),
            ]
        }
        return [
            "machine": result.machineID,
            "supported": result.report != nil,
            "fast": result.request.fast,
            "probe": result.request.probe,
            "checked_at": CloudSecretsSocketParams.iso8601(result.checkedAt),
            "model_routing": result.report?.hasModelRouting ?? false,
            "sign_in_modes": result.report?.hasSignInModes ?? false,
            "agents": agents,
            "problems": assessments.filter { $0.status == .problem }.count,
            "attention": assessments.filter { $0.status == .attention }.count,
        ]
    }
}
