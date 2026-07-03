import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    private static let hostedSubrouterOriginURL = "https://subrouter.cmux.dev"

    private struct SubrouterEndpoint {
        let source: String
        let originURL: String
        let customBaseURL: String
        let codexBackendURL: String
        let codexChatGPTBaseURL: String
    }

    func runSubrouter(commandName: String, commandArgs: [String], jsonOutput: Bool) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "status"
        let rest = commandArgs.isEmpty ? [] : Array(commandArgs.dropFirst())
        switch subcommand {
        case "status":
            try runSubrouterStatus(commandName: commandName, commandArgs: rest, jsonOutput: jsonOutput)
        case "doctor":
            try runSubrouterDoctor(commandName: commandName, commandArgs: rest, jsonOutput: jsonOutput)
        case "env":
            try runSubrouterEnv(commandName: commandName, commandArgs: rest, jsonOutput: jsonOutput)
        case "credits":
            try runSubrouterCredits(commandName: commandName, commandArgs: rest, jsonOutput: jsonOutput)
        case "help":
            print(subrouterUsage(commandName: commandName))
        default:
            throw CLIError(message: """
                Unknown subrouter subcommand: \(subcommand)

                \(subrouterUsage(commandName: commandName))
                """)
        }
    }

    func subrouterUsage(commandName: String) -> String {
        """
        Usage: cmux \(commandName) <status|doctor|env|credits> [args...]

        Inspect and configure cmux Subrouter integration. `cmux sr` is an alias
        for `cmux subrouter`.

        Subcommands:
          status                         Show current support state.
          doctor [--url <url>|--hosted]  Check endpoint configuration.
          env [--url <url>|--hosted] [--format shell|codex-toml|json]
                                         Print environment or Codex config values for a Subrouter endpoint.
          credits [--token <token>] [--control-plane-url <url>|--hosted]
                                         Show Codex rate-limit reset credits for the authenticated account.

        Hosted endpoint: \(Self.hostedSubrouterOriginURL)

        Today, cmux supports Codex/Hermes endpoint preservation and a deployable
        Durable Object control-plane scaffold. Managed Cloud VM router provisioning,
        default Freestyle image baking, and cmux-managed data-plane routing are pending.
        """
    }

    private func runSubrouterStatus(commandName: String, commandArgs: [String], jsonOutput: Bool) throws {
        try rejectUnexpectedSubrouterArguments(commandArgs, commandName: commandName, subcommand: "status")
        let endpoint = try configuredSubrouterEndpoint(environment: ProcessInfo.processInfo.environment)
        let payload = subrouterStatusPayload(endpoint: endpoint)
        if jsonOutput {
            print(jsonString(payload))
            return
        }

        print("Subrouter status")
        print("  CLI commands: cmux subrouter, cmux sr")
        print("  Durable Object control-plane CI/CD: available")
        print("  Managed Cloud VM router lifecycle: pending")
        print("  Data-plane routing managed by cmux: pending")
        print("  Supported path today: Codex/Hermes endpoint env and Codex config preservation")
        print("  Cloud VM image baking: pending for the default Freestyle image")
        if let endpoint {
            print("  Configured endpoint: \(endpoint.originURL) (\(endpoint.source))")
        } else {
            print("  Configured endpoint: none")
        }
        print("  Hosted endpoint: \(Self.hostedSubrouterOriginURL)")
        print("  Next setup command: cmux \(commandName) env --hosted")
    }

    private func runSubrouterDoctor(commandName: String, commandArgs: [String], jsonOutput: Bool) throws {
        let (useHosted, afterHosted) = removeSubrouterFlag(commandArgs, name: "--hosted")
        let (urlOpt, remaining) = parseOption(afterHosted, name: "--url")
        if useHosted && urlOpt != nil {
            throw CLIError(message: "Usage: cmux \(commandName) doctor [--url <url>|--hosted]")
        }
        try rejectUnexpectedSubrouterArguments(remaining, commandName: commandName, subcommand: "doctor")
        let endpoint = try resolveSubrouterEndpoint(
            explicitURL: useHosted ? Self.hostedSubrouterOriginURL : urlOpt,
            explicitSource: useHosted ? "--hosted" : (urlOpt == nil ? nil : "--url"),
            environment: ProcessInfo.processInfo.environment
        )
        let ready = endpoint != nil
        let payload: [String: Any] = [
            "ready": ready,
            "durable_object_control_plane_cicd": true,
            "managed_cloud_vm_lifecycle": false,
            "data_plane_managed_by_cmux": false,
            "freestyle_default_image_bakes_subrouter": false,
            "supported_agents_today": ["codex", "hermes"],
            "pending_agents": ["claude", "opencode"],
            "endpoint": endpointPayload(endpoint),
            "checks": [
                [
                    "name": "endpoint_config",
                    "ok": ready,
                    "detail": ready ? "Subrouter endpoint configured." : "Set SUBROUTER_REMOTE_URL, CUSTOM_BASE_URL, HERMES_CODEX_BASE_URL, pass --url, or pass --hosted."
                ],
                [
                    "name": "cmux_agent_launch_env",
                    "ok": true,
                    "detail": "cmux preserves CUSTOM_BASE_URL and HERMES_CODEX_BASE_URL for agent launches."
                ],
                [
                    "name": "durable_object_control_plane_cicd",
                    "ok": true,
                    "detail": "workers/subrouter has Wrangler CI/CD and Durable Object class migrations."
                ],
                [
                    "name": "managed_cloud_lifecycle",
                    "ok": false,
                    "detail": "The Durable Object control plane can deploy, but it does not provision router VMs or manage data-plane routing yet."
                ]
            ]
        ]
        if jsonOutput {
            print(jsonString(payload))
            return
        }

        print("Subrouter doctor")
        print("  endpoint_config: \(ready ? "ok" : "missing")")
        if let endpoint {
            print("  origin: \(endpoint.originURL) (\(endpoint.source))")
            print("  CUSTOM_BASE_URL: \(endpoint.customBaseURL)")
            print("  HERMES_CODEX_BASE_URL: \(endpoint.codexBackendURL)")
        } else {
            print("  Set an endpoint with SUBROUTER_REMOTE_URL, pass --url, or pass --hosted.")
        }
        print("  cmux_agent_launch_env: ok")
        print("  durable_object_control_plane_cicd: ok")
        print("  managed_cloud_lifecycle: pending")
        print("  data_plane_managed_by_cmux: pending")
    }

    private func runSubrouterEnv(commandName: String, commandArgs: [String], jsonOutput: Bool) throws {
        let (useHosted, afterHosted) = removeSubrouterFlag(commandArgs, name: "--hosted")
        let (urlOpt, afterURL) = parseOption(afterHosted, name: "--url")
        let (formatOpt, remaining) = parseOption(afterURL, name: "--format")
        let positional = remaining.filter { !$0.hasPrefix("-") }
        if positional.count > 1 {
            throw CLIError(message: "Usage: cmux \(commandName) env [--url <url>|--hosted] [--format shell|codex-toml|json]")
        }
        if let unknown = remaining.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(message: "cmux \(commandName) env: unknown flag '\(unknown)'")
        }
        if useHosted && (urlOpt != nil || positional.first != nil) {
            throw CLIError(message: "Usage: cmux \(commandName) env [--url <url>|--hosted] [--format shell|codex-toml|json]")
        }
        let explicitURL = urlOpt ?? positional.first
        guard let endpoint = try resolveSubrouterEndpoint(
            explicitURL: useHosted ? Self.hostedSubrouterOriginURL : explicitURL,
            explicitSource: useHosted ? "--hosted" : (explicitURL == nil ? nil : (urlOpt == nil ? "argument" : "--url")),
            environment: ProcessInfo.processInfo.environment
        ) else {
            throw CLIError(message: """
                No Subrouter endpoint configured.

                Try:
                  cmux \(commandName) env --hosted
                """)
        }

        let format = jsonOutput ? "json" : (formatOpt ?? "shell").lowercased()
        switch format {
        case "json":
            print(jsonString(subrouterEnvPayload(endpoint)))
        case "shell":
            print("export SUBROUTER_REMOTE_URL=\(shellQuote(endpoint.originURL))")
            print("export CUSTOM_BASE_URL=\(shellQuote(endpoint.customBaseURL))")
            print("export HERMES_CODEX_BASE_URL=\(shellQuote(endpoint.codexBackendURL))")
        case "codex-toml", "codex":
            print("openai_base_url = \"\(subrouterTomlBasicStringContent(endpoint.customBaseURL))\"")
            print("chatgpt_base_url = \"\(subrouterTomlBasicStringContent(endpoint.codexChatGPTBaseURL))\"")
        default:
            throw CLIError(message: "cmux \(commandName) env: unknown format '\(format)' (expected shell, codex-toml, or json)")
        }
    }

    private func configuredSubrouterEndpoint(environment: [String: String]) throws -> SubrouterEndpoint? {
        let candidates: [(source: String, value: String?)] = [
            ("SUBROUTER_REMOTE_URL", environment["SUBROUTER_REMOTE_URL"]),
            (HermesAgentCodexEnvironment.customBaseURLEnvironmentKey, environment[HermesAgentCodexEnvironment.customBaseURLEnvironmentKey]),
            (HermesAgentCodexEnvironment.codexBaseURLEnvironmentKey, environment[HermesAgentCodexEnvironment.codexBaseURLEnvironmentKey]),
        ]
        for candidate in candidates {
            guard let value = normalizedSubrouterEnvValue(candidate.value) else { continue }
            return try normalizeSubrouterEndpoint(value, source: candidate.source)
        }
        return nil
    }

    private func resolveSubrouterEndpoint(
        explicitURL: String?,
        explicitSource: String?,
        environment: [String: String]
    ) throws -> SubrouterEndpoint? {
        if let explicitURL = normalizedSubrouterEnvValue(explicitURL) {
            return try normalizeSubrouterEndpoint(explicitURL, source: explicitSource ?? "argument")
        }
        return try configuredSubrouterEndpoint(environment: environment)
    }

    private func normalizeSubrouterEndpoint(_ rawValue: String, source: String) throws -> SubrouterEndpoint {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = stripSubrouterTrailingSlashes(raw)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.query == nil,
              url.fragment == nil else {
            throw CLIError(message: "Invalid Subrouter URL from \(source): \(rawValue)")
        }

        let originURL: String
        if trimmed.hasSuffix("/v1") {
            originURL = String(trimmed.dropLast("/v1".count))
        } else if trimmed.hasSuffix("/backend-api/codex") {
            originURL = String(trimmed.dropLast("/backend-api/codex".count))
        } else if trimmed.hasSuffix("/backend-api") {
            originURL = String(trimmed.dropLast("/backend-api".count))
        } else {
            originURL = trimmed
        }
        guard !originURL.isEmpty else {
            throw CLIError(message: "Invalid Subrouter URL from \(source): \(rawValue)")
        }
        return SubrouterEndpoint(
            source: source,
            originURL: originURL,
            customBaseURL: "\(originURL)/v1",
            codexBackendURL: "\(originURL)/backend-api/codex",
            codexChatGPTBaseURL: "\(originURL)/backend-api"
        )
    }

    private func stripSubrouterTrailingSlashes(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") {
            let candidate = String(result.dropLast())
            guard let url = URL(string: candidate),
                  url.scheme != nil,
                  url.host != nil else {
                break
            }
            result = candidate
        }
        return result
    }

    private func subrouterStatusPayload(endpoint: SubrouterEndpoint?) -> [String: Any] {
        [
            "cli": [
                "command": "subrouter",
                "alias": "sr"
            ],
            "durable_object_control_plane_cicd": true,
            "managed_cloud_vm_lifecycle": false,
            "data_plane_managed_by_cmux": false,
            "freestyle_default_image_bakes_subrouter": false,
            "hosted_origin_url": Self.hostedSubrouterOriginURL,
            "supported_path_today": [
                "codex_hermes_endpoint_env": true,
                "codex_config_preservation": true
            ],
            "endpoint": endpointPayload(endpoint)
        ]
    }

    private func subrouterEnvPayload(_ endpoint: SubrouterEndpoint) -> [String: Any] {
        [
            "source": endpoint.source,
            "origin_url": endpoint.originURL,
            "env": [
                "SUBROUTER_REMOTE_URL": endpoint.originURL,
                HermesAgentCodexEnvironment.customBaseURLEnvironmentKey: endpoint.customBaseURL,
                HermesAgentCodexEnvironment.codexBaseURLEnvironmentKey: endpoint.codexBackendURL
            ],
            "codex_config": [
                "openai_base_url": endpoint.customBaseURL,
                "chatgpt_base_url": endpoint.codexChatGPTBaseURL
            ]
        ]
    }

    private func endpointPayload(_ endpoint: SubrouterEndpoint?) -> Any {
        guard let endpoint else { return NSNull() }
        return [
            "source": endpoint.source,
            "origin_url": endpoint.originURL,
            HermesAgentCodexEnvironment.customBaseURLEnvironmentKey: endpoint.customBaseURL,
            HermesAgentCodexEnvironment.codexBaseURLEnvironmentKey: endpoint.codexBackendURL,
            "codex_chatgpt_base_url": endpoint.codexChatGPTBaseURL
        ]
    }

    private func rejectUnexpectedSubrouterArguments(
        _ args: [String],
        commandName: String,
        subcommand: String
    ) throws {
        guard args.isEmpty else {
            throw CLIError(message: "Usage: cmux \(commandName) \(subcommand)")
        }
    }

    private func removeSubrouterFlag(_ args: [String], name: String) -> (Bool, [String]) {
        var found = false
        var remaining: [String] = []
        remaining.reserveCapacity(args.count)
        for arg in args {
            if arg == name {
                found = true
            } else {
                remaining.append(arg)
            }
        }
        return (found, remaining)
    }

    private func normalizedSubrouterEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func subrouterTomlBasicStringContent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func runSubrouterCredits(commandName: String, commandArgs: [String], jsonOutput: Bool) throws {
        let (tokenOpt, afterToken) = parseOption(commandArgs, name: "--token")
        let (controlPlaneURLOpt, afterControlPlaneURL) = parseOption(afterToken, name: "--control-plane-url")
        let (useHosted, remaining) = removeSubrouterFlag(afterControlPlaneURL, name: "--hosted")
        if useHosted && controlPlaneURLOpt != nil {
            throw CLIError(message: "Usage: cmux \(commandName) credits [--token <token>] [--control-plane-url <url>|--hosted]")
        }
        try rejectUnexpectedSubrouterArguments(remaining, commandName: commandName, subcommand: "credits")

        let environment = ProcessInfo.processInfo.environment
        let authToken = tokenOpt ?? environment["CODEX_AUTH_TOKEN"]
        guard let authToken, !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: """
                cmux \(commandName) credits requires a Codex auth token.

                Pass --token or set CODEX_AUTH_TOKEN. The token is forwarded to the
                Subrouter control plane, which proxies the ChatGPT rate-limit-reset-credits
                endpoint. cmux does not persist the token.
                """)
        }

        let controlPlaneURL: String
        if useHosted {
            controlPlaneURL = Self.hostedSubrouterOriginURL
        } else if let explicit = controlPlaneURLOpt ?? environment["SUBROUTER_CONTROL_PLANE_URL"] {
            controlPlaneURL = explicit
        } else if let endpoint = try configuredSubrouterEndpoint(environment: environment) {
            controlPlaneURL = endpoint.originURL
        } else {
            controlPlaneURL = Self.hostedSubrouterOriginURL
        }

        let creditsURL = "\(stripSubrouterTrailingSlashes(controlPlaneURL))/v1/subrouter/rate-limit-reset-credits"
        let result = try fetchSubrouterRateLimitResetCredits(url: creditsURL, authToken: authToken)

        if jsonOutput {
            print(jsonString(result))
            return
        }

        guard let wrapper = result["rate_limit_reset_credits"] as? [String: Any],
              let availableCount = wrapper["available_count"] as? Int,
              let credits = wrapper["credits"] as? [[String: Any]] else {
            throw CLIError(message: "Unexpected response from Subrouter control plane")
        }

        print("Codex rate-limit reset credits")
        print("  available: \(availableCount)")
        if credits.isEmpty {
            print("  credits: none")
        } else {
            print("  credits:")
            for credit in credits {
                let id = credit["id"] as? String ?? "<unknown>"
                let status = credit["status"] as? String ?? "unknown"
                let title = credit["title"] as? String ?? "Rate limit reset"
                let consumedMarker = status == "available" ? "not consumed" : "consumed"
                print("    - \(id): \(title) (\(status), \(consumedMarker))")
            }
        }
    }

    private func fetchSubrouterRateLimitResetCredits(url: String, authToken: String) throws -> [String: Any] {
        guard let requestURL = URL(string: url) else {
            throw CLIError(message: "Invalid Subrouter credits URL: \(url)")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authToken.starts(with: "Bearer ") ? authToken : "Bearer \(authToken)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let finished = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error>?
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
                finished.signal()
                return
            }
            guard let data else {
                result = .failure(CLIError(message: "No data received from Subrouter control plane"))
                finished.signal()
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure(CLIError(message: "Non-HTTP response from Subrouter control plane"))
                finished.signal()
                return
            }
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                result = .failure(CLIError(message: "Subrouter control plane returned \(httpResponse.statusCode): \(body)"))
                finished.signal()
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dictionary = object as? [String: Any] else {
                result = .failure(CLIError(message: "Invalid JSON from Subrouter control plane"))
                finished.signal()
                return
            }
            result = .success(dictionary)
            finished.signal()
        }
        task.resume()
        if finished.wait(timeout: .now() + 35) == .timedOut {
            task.cancel()
            throw CLIError(message: "Timed out waiting for Subrouter control plane")
        }

        switch result {
        case .success(let dictionary):
            return dictionary
        case .failure(let error):
            throw error
        case .none:
            throw CLIError(message: "Unknown error waiting for Subrouter control plane")
        }
    }
}
