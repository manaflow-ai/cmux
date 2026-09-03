import Foundation

// `coderouter.*` socket methods behind `cmux coderouter <status|machines|claude>`.
// The CLI is presentation only; the app owns the Stack session and the team
// selection, so the credential a user pastes travels CLI -> local socket ->
// this handler -> cmux backend and nowhere else. Every other `cmux coderouter`
// or `cmux cr` invocation is exec'd into the installed CodeRouter CLI before
// the socket is opened (see `runCoderouterAlias`).
extension TerminalController {
    nonisolated func socketWorkerCoderouterResponse(
        method: String,
        id: Any?,
        params: [String: Any]
    ) -> String {
        let teamID = Self.coderouterString(params["teamId"]) ?? Self.coderouterString(params["team_id"])
        switch method {
        case "coderouter.claude_upstream.get":
            return coderouterCall(id: id) {
                let result = try await CoderouterClient.shared.claudeUpstream(teamID: teamID)
                return (result.foundationObject as? [String: Any]) ?? [:]
            }
        case "coderouter.claude_upstream.set":
            let input: ClaudeUpstreamInput
            switch Self.claudeUpstreamInput(from: params) {
            case .success(let parsed):
                input = parsed
            case .failure(let message):
                return v2Error(id: id, code: "invalid_params", message: message)
            }
            return coderouterCall(id: id) {
                let result = try await CoderouterClient.shared.setClaudeUpstream(input, teamID: teamID)
                return (result.foundationObject as? [String: Any]) ?? [:]
            }
        case "coderouter.claude_upstream.clear":
            return coderouterCall(id: id) {
                let result = try await CoderouterClient.shared.clearClaudeUpstream(teamID: teamID)
                return (result.foundationObject as? [String: Any]) ?? [:]
            }
        case "coderouter.machines":
            return coderouterCall(id: id) {
                guard let client = await MachineUsageClient.shared else {
                    throw CoderouterClientError.malformedResponse("machine usage is not available yet; retry in a moment")
                }
                let usage = try await client.teamUsage(teamID: teamID)
                return Self.machineUsagePayload(usage)
            }
        default:
            return v2Error(id: id, code: "method_not_found", message: "Unknown method")
        }
    }

    private enum ClaudeUpstreamParse {
        case success(ClaudeUpstreamInput)
        case failure(String)
    }

    /// Socket params -> credential input. Shape checks here are the cheap
    /// client-side ones (which fields a kind needs); the backend validates the
    /// token grammar and is the authority.
    private nonisolated static func claudeUpstreamInput(from params: [String: Any]) -> ClaudeUpstreamParse {
        guard let kind = coderouterString(params["kind"])?.lowercased(), !kind.isEmpty else {
            return .failure("coderouter.claude_upstream.set requires `kind`: anthropic_api_key, anthropic_oauth, or bedrock.")
        }
        switch kind {
        case "anthropic_api_key":
            guard let apiKey = socketWorkerSecret(params["apiKey"]) else {
                return .failure("anthropic_api_key requires `apiKey`.")
            }
            return .success(.anthropicAPIKey(apiKey))
        case "anthropic_oauth":
            guard let token = socketWorkerSecret(params["token"]) else {
                return .failure("anthropic_oauth requires `token` (from `claude setup-token`).")
            }
            return .success(.anthropicOAuth(token: token))
        case "bedrock":
            guard let region = socketWorkerSecret(params["region"]) else {
                return .failure("bedrock requires `region`.")
            }
            guard let accessKeyID = socketWorkerSecret(params["accessKeyId"]) else {
                return .failure("bedrock requires `accessKeyId`.")
            }
            guard let secretAccessKey = socketWorkerSecret(params["secretAccessKey"]) else {
                return .failure("bedrock requires `secretAccessKey`.")
            }
            let sessionToken = socketWorkerSecret(params["sessionToken"])
            var modelIDs: [String: String] = [:]
            if let raw = params["modelIds"] {
                guard let object = raw as? [String: Any] else {
                    return .failure("bedrock `modelIds` must be an object of claude model id -> Bedrock model id.")
                }
                for (key, value) in object {
                    guard let mapped = value as? String, !mapped.isEmpty else {
                        return .failure("bedrock `modelIds[\(key)]` must be a non-empty string.")
                    }
                    modelIDs[key] = mapped
                }
            }
            return .success(.bedrock(
                region: region,
                accessKeyID: accessKeyID,
                secretAccessKey: secretAccessKey,
                sessionToken: sessionToken,
                modelIDs: modelIDs
            ))
        default:
            return .failure("Unknown Claude upstream kind '\(kind)'. Use anthropic_api_key, anthropic_oauth, or bedrock.")
        }
    }

    /// Socket params arrive as untyped JSON; only string values are accepted
    /// (numbers or objects in a credential field are a caller bug, not data).
    private nonisolated static func coderouterString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func socketWorkerSecret(_ value: Any?) -> String? {
        coderouterString(value)
    }

    /// Mirrors the `GET /api/coderouter/vm-usage/team` JSON so `--json` output
    /// matches the web contract (`vmId`, `providerVmId`, `displayName`, `totals`).
    private nonisolated static func machineUsagePayload(_ usage: TeamMachineUsage) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func totals(_ value: MachineUsageTotals) -> [String: Any] {
            [
                "inputTokens": value.inputTokens,
                "cachedInputTokens": value.cachedInputTokens,
                "outputTokens": value.outputTokens,
                "totalTokens": value.totalTokens,
                "apiEquivalentUsd": value.apiEquivalentUsd,
            ]
        }
        return [
            "teamId": usage.teamID,
            "periodDays": usage.periodDays,
            "kind": usage.kind.rawValue,
            "asOf": usage.asOf.map(formatter.string(from:)) as Any? ?? NSNull(),
            "machines": usage.machines.map { machine -> [String: Any] in
                [
                    "vmId": machine.vmID,
                    "providerVmId": machine.providerVmID as Any? ?? NSNull(),
                    "displayName": machine.displayName as Any? ?? NSNull(),
                    "totals": totals(machine.totals),
                ]
            },
        ]
    }

    /// `v2VmCall` with the coderouter client's sign-in failures surfaced as the
    /// stable `auth_required` code the CLI already understands for `vm`.
    private nonisolated func coderouterCall(
        id: Any?,
        _ work: @escaping () async throws -> [String: Any]
    ) -> String {
        v2VmCall(id: id, timeoutSeconds: 60) {
            do {
                return try await work()
            } catch CoderouterClientError.notSignedIn {
                throw VMClientError.notSignedIn
            } catch CoderouterClientError.sessionRefreshFailed {
                throw VMClientError.sessionRefreshFailed
            } catch MachineUsageClientError.notSignedIn {
                throw VMClientError.notSignedIn
            } catch MachineUsageClientError.sessionRefreshFailed {
                throw VMClientError.sessionRefreshFailed
            }
        }
    }
}
