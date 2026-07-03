import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    private static let hostedSubrouterOriginURL = "https://subrouter.cmux.dev"

    private enum SubrouterText {
        static let unknownSubcommand = String(localized: "cli.subrouter.error.unknownSubcommand", defaultValue: """
            Unknown subrouter subcommand: %@

            %@
            """)
        static let usageTemplate = String(localized: "cli.subrouter.usage", defaultValue: """
            Usage: cmux %@ <status|doctor|env|credits> [args...]

            Inspect and configure cmux Subrouter integration. `cmux sr` is an alias
            for `cmux subrouter`.

            Subcommands:
              status                         Show current support state.
              doctor [--url <url>|--hosted]  Check endpoint configuration.
              env [--url <url>|--hosted] [--format shell|codex-toml|json]
                                             Print environment or Codex config values for a Subrouter endpoint.
              credits [--token <token>] [--control-plane-url <url>|--hosted]
                                             Show Codex rate-limit reset credits for the authenticated account.

            Hosted endpoint: %@

            Today, cmux supports Codex/Hermes endpoint preservation and a deployable
            Durable Object control-plane scaffold. Managed Cloud VM router provisioning,
            default Freestyle image baking, and cmux-managed data-plane routing are pending.
            """)
        static let statusTitle = String(localized: "cli.subrouter.status.title", defaultValue: "Subrouter status")
        static let statusCLICommands = String(localized: "cli.subrouter.status.cliCommands", defaultValue: "  CLI commands: cmux subrouter, cmux sr")
        static let statusCICD = String(localized: "cli.subrouter.status.cicd", defaultValue: "  Durable Object control-plane CI/CD: available")
        static let statusVMLifecycle = String(localized: "cli.subrouter.status.vmLifecycle", defaultValue: "  Managed Cloud VM router lifecycle: pending")
        static let statusDataPlane = String(localized: "cli.subrouter.status.dataPlane", defaultValue: "  Data-plane routing managed by cmux: pending")
        static let statusSupportedPath = String(localized: "cli.subrouter.status.supportedPath", defaultValue: "  Supported path today: Codex/Hermes endpoint env and Codex config preservation")
        static let statusImageBaking = String(localized: "cli.subrouter.status.imageBaking", defaultValue: "  Cloud VM image baking: pending for the default Freestyle image")
        static let statusConfiguredEndpoint = String(localized: "cli.subrouter.status.configuredEndpoint", defaultValue: "  Configured endpoint: %@ (%@)")
        static let statusConfiguredEndpointNone = String(localized: "cli.subrouter.status.configuredEndpoint.none", defaultValue: "  Configured endpoint: none")
        static let statusHostedEndpoint = String(localized: "cli.subrouter.status.hostedEndpoint", defaultValue: "  Hosted endpoint: %@")
        static let statusNextSetup = String(localized: "cli.subrouter.status.nextSetup", defaultValue: "  Next setup command: cmux %@ env --hosted")
        static let usageDoctor = String(localized: "cli.subrouter.usage.doctor", defaultValue: "Usage: cmux %@ doctor [--url <url>|--hosted]")
        static let usageEnv = String(localized: "cli.subrouter.usage.env", defaultValue: "Usage: cmux %@ env [--url <url>|--hosted] [--format shell|codex-toml|json]")
        static let usageCredits = String(localized: "cli.subrouter.usage.credits", defaultValue: "Usage: cmux %@ credits [--token <token>] [--control-plane-url <url>|--hosted]")
        static let endpointConfiguredDetail = String(localized: "cli.subrouter.doctor.detail.endpointConfigured", defaultValue: "Subrouter endpoint configured.")
        static let endpointMissingDetail = String(localized: "cli.subrouter.doctor.detail.endpointMissing", defaultValue: "Set SUBROUTER_REMOTE_URL, CUSTOM_BASE_URL, HERMES_CODEX_BASE_URL, pass --url, or pass --hosted.")
        static let agentLaunchDetail = String(localized: "cli.subrouter.doctor.detail.agentLaunch", defaultValue: "cmux preserves CUSTOM_BASE_URL and HERMES_CODEX_BASE_URL for agent launches.")
        static let cicdDetail = String(localized: "cli.subrouter.doctor.detail.cicd", defaultValue: "workers/subrouter has Wrangler CI/CD and Durable Object class migrations.")
        static let managedLifecycleDetail = String(localized: "cli.subrouter.doctor.detail.managedLifecycle", defaultValue: "The Durable Object control plane can deploy, but it does not provision router VMs or manage data-plane routing yet.")
        static let doctorTitle = String(localized: "cli.subrouter.doctor.title", defaultValue: "Subrouter doctor")
        static let doctorEndpointStatus = String(localized: "cli.subrouter.doctor.endpointStatus", defaultValue: "  endpoint_config: %@")
        static let doctorEndpointOK = String(localized: "cli.subrouter.doctor.endpoint.ok", defaultValue: "ok")
        static let doctorEndpointMissing = String(localized: "cli.subrouter.doctor.endpoint.missing", defaultValue: "missing")
        static let doctorOrigin = String(localized: "cli.subrouter.doctor.origin", defaultValue: "  origin: %@ (%@)")
        static let doctorCustomBaseURL = String(localized: "cli.subrouter.doctor.customBaseURL", defaultValue: "  CUSTOM_BASE_URL: %@")
        static let doctorCodexBaseURL = String(localized: "cli.subrouter.doctor.codexBaseURL", defaultValue: "  HERMES_CODEX_BASE_URL: %@")
        static let doctorSetEndpoint = String(localized: "cli.subrouter.doctor.setEndpoint", defaultValue: "  Set an endpoint with SUBROUTER_REMOTE_URL, pass --url, or pass --hosted.")
        static let doctorAgentLaunchOK = String(localized: "cli.subrouter.doctor.agentLaunchOK", defaultValue: "  cmux_agent_launch_env: ok")
        static let doctorCICDOK = String(localized: "cli.subrouter.doctor.cicdOK", defaultValue: "  durable_object_control_plane_cicd: ok")
        static let doctorManagedLifecyclePending = String(localized: "cli.subrouter.doctor.managedLifecyclePending", defaultValue: "  managed_cloud_lifecycle: pending")
        static let doctorDataPlanePending = String(localized: "cli.subrouter.doctor.dataPlanePending", defaultValue: "  data_plane_managed_by_cmux: pending")
        static let envUnknownFlag = String(localized: "cli.subrouter.env.error.unknownFlag", defaultValue: "cmux %@ env: unknown flag '%@'")
        static let envNoEndpoint = String(localized: "cli.subrouter.env.error.noEndpoint", defaultValue: """
            No Subrouter endpoint configured.

            Try:
              cmux %@ env --hosted
            """)
        static let envUnknownFormat = String(localized: "cli.subrouter.env.error.unknownFormat", defaultValue: "cmux %@ env: unknown format '%@' (expected shell, codex-toml, or json)")
        static let invalidURL = String(localized: "cli.subrouter.error.invalidURL", defaultValue: "Invalid Subrouter URL from %@: %@")
        static let usageSubcommand = String(localized: "cli.subrouter.usage.subcommand", defaultValue: "Usage: cmux %@ %@")
        static let creditsMissingToken = String(localized: "cli.subrouter.credits.error.missingToken", defaultValue: """
            cmux %@ credits requires a Codex auth token.

            Pass --token or set CODEX_AUTH_TOKEN. The token is forwarded to the
            Subrouter control plane, which proxies the ChatGPT rate-limit-reset-credits
            endpoint. cmux does not persist the token.
            """)
        static let creditsUnexpectedResponse = String(localized: "cli.subrouter.credits.error.unexpectedResponse", defaultValue: "Unexpected response from Subrouter control plane")
        static let creditsTitle = String(localized: "cli.subrouter.credits.title", defaultValue: "Codex rate-limit reset credits")
        static let creditsAvailable = String(localized: "cli.subrouter.credits.available", defaultValue: "  available: %lld")
        static let creditsNone = String(localized: "cli.subrouter.credits.none", defaultValue: "  credits: none")
        static let creditsHeader = String(localized: "cli.subrouter.credits.header", defaultValue: "  credits:")
        static let creditsUnknownID = String(localized: "cli.subrouter.credits.unknownID", defaultValue: "<unknown>")
        static let creditsUnknownStatus = String(localized: "cli.subrouter.credits.unknownStatus", defaultValue: "unknown")
        static let creditsDefaultTitle = String(localized: "cli.subrouter.credits.defaultTitle", defaultValue: "Rate limit reset")
        static let creditsConsumed = String(localized: "cli.subrouter.credits.consumed", defaultValue: "consumed")
        static let creditsNotConsumed = String(localized: "cli.subrouter.credits.notConsumed", defaultValue: "not consumed")
        static let creditsItem = String(localized: "cli.subrouter.credits.item", defaultValue: "    - %@: %@ (%@, %@)")
        static let creditsInvalidURL = String(localized: "cli.subrouter.credits.error.invalidURL", defaultValue: "Invalid Subrouter credits URL: %@")
        static let creditsNoData = String(localized: "cli.subrouter.credits.error.noData", defaultValue: "No data received from Subrouter control plane")
        static let creditsNonHTTP = String(localized: "cli.subrouter.credits.error.nonHTTP", defaultValue: "Non-HTTP response from Subrouter control plane")
        static let creditsHTTPStatus = String(localized: "cli.subrouter.credits.error.httpStatus", defaultValue: "Subrouter control plane returned HTTP %lld")
        static let creditsInvalidJSON = String(localized: "cli.subrouter.credits.error.invalidJSON", defaultValue: "Invalid JSON from Subrouter control plane")
        static let creditsTimeout = String(localized: "cli.subrouter.credits.error.timeout", defaultValue: "Timed out waiting for Subrouter control plane")
    }

    private struct SubrouterEndpoint {
        let source: String
        let originURL: String
        let customBaseURL: String
        let codexBackendURL: String
        let codexChatGPTBaseURL: String
    }

    func runSubrouter(commandName: String, commandArgs: [String], jsonOutput: Bool) async throws {
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
            try await runSubrouterCredits(commandName: commandName, commandArgs: rest, jsonOutput: jsonOutput)
        case "help":
            print(subrouterUsage(commandName: commandName))
        default:
            throw CLIError(message: String.localizedStringWithFormat(
                SubrouterText.unknownSubcommand,
                subcommand,
                subrouterUsage(commandName: commandName)
            ))
        }
    }

    func subrouterUsage(commandName: String) -> String {
        String.localizedStringWithFormat(
            SubrouterText.usageTemplate,
            commandName,
            Self.hostedSubrouterOriginURL
        )
    }

    private func runSubrouterStatus(commandName: String, commandArgs: [String], jsonOutput: Bool) throws {
        try rejectUnexpectedSubrouterArguments(commandArgs, commandName: commandName, subcommand: "status")
        let endpoint = try configuredSubrouterEndpoint(environment: ProcessInfo.processInfo.environment)
        let payload = subrouterStatusPayload(endpoint: endpoint)
        if jsonOutput {
            print(jsonString(payload))
            return
        }

        print(SubrouterText.statusTitle)
        print(SubrouterText.statusCLICommands)
        print(SubrouterText.statusCICD)
        print(SubrouterText.statusVMLifecycle)
        print(SubrouterText.statusDataPlane)
        print(SubrouterText.statusSupportedPath)
        print(SubrouterText.statusImageBaking)
        if let endpoint {
            print(String.localizedStringWithFormat(SubrouterText.statusConfiguredEndpoint, endpoint.originURL, endpoint.source))
        } else {
            print(SubrouterText.statusConfiguredEndpointNone)
        }
        print(String.localizedStringWithFormat(SubrouterText.statusHostedEndpoint, Self.hostedSubrouterOriginURL))
        print(String.localizedStringWithFormat(SubrouterText.statusNextSetup, commandName))
    }

    private func runSubrouterDoctor(commandName: String, commandArgs: [String], jsonOutput: Bool) throws {
        let (useHosted, afterHosted) = removeSubrouterFlag(commandArgs, name: "--hosted")
        let (urlOpt, remaining) = parseOption(afterHosted, name: "--url")
        if useHosted && urlOpt != nil {
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.usageDoctor, commandName))
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
                    "detail": ready ? SubrouterText.endpointConfiguredDetail : SubrouterText.endpointMissingDetail
                ],
                [
                    "name": "cmux_agent_launch_env",
                    "ok": true,
                    "detail": SubrouterText.agentLaunchDetail
                ],
                [
                    "name": "durable_object_control_plane_cicd",
                    "ok": true,
                    "detail": SubrouterText.cicdDetail
                ],
                [
                    "name": "managed_cloud_lifecycle",
                    "ok": false,
                    "detail": SubrouterText.managedLifecycleDetail
                ]
            ]
        ]
        if jsonOutput {
            print(jsonString(payload))
            return
        }

        print(SubrouterText.doctorTitle)
        print(String.localizedStringWithFormat(
            SubrouterText.doctorEndpointStatus,
            ready ? SubrouterText.doctorEndpointOK : SubrouterText.doctorEndpointMissing
        ))
        if let endpoint {
            print(String.localizedStringWithFormat(SubrouterText.doctorOrigin, endpoint.originURL, endpoint.source))
            print(String.localizedStringWithFormat(SubrouterText.doctorCustomBaseURL, endpoint.customBaseURL))
            print(String.localizedStringWithFormat(SubrouterText.doctorCodexBaseURL, endpoint.codexBackendURL))
        } else {
            print(SubrouterText.doctorSetEndpoint)
        }
        print(SubrouterText.doctorAgentLaunchOK)
        print(SubrouterText.doctorCICDOK)
        print(SubrouterText.doctorManagedLifecyclePending)
        print(SubrouterText.doctorDataPlanePending)
    }

    private func runSubrouterEnv(commandName: String, commandArgs: [String], jsonOutput: Bool) throws {
        let (useHosted, afterHosted) = removeSubrouterFlag(commandArgs, name: "--hosted")
        let (urlOpt, afterURL) = parseOption(afterHosted, name: "--url")
        let (formatOpt, remaining) = parseOption(afterURL, name: "--format")
        let positional = remaining.filter { !$0.hasPrefix("-") }
        if positional.count > 1 {
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.usageEnv, commandName))
        }
        if let unknown = remaining.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.envUnknownFlag, commandName, unknown))
        }
        if useHosted && (urlOpt != nil || positional.first != nil) {
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.usageEnv, commandName))
        }
        let explicitURL = urlOpt ?? positional.first
        guard let endpoint = try resolveSubrouterEndpoint(
            explicitURL: useHosted ? Self.hostedSubrouterOriginURL : explicitURL,
            explicitSource: useHosted ? "--hosted" : (explicitURL == nil ? nil : (urlOpt == nil ? "argument" : "--url")),
            environment: ProcessInfo.processInfo.environment
        ) else {
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.envNoEndpoint, commandName))
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
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.envUnknownFormat, commandName, format))
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
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.invalidURL, source, rawValue))
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
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.invalidURL, source, rawValue))
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
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.usageSubcommand, commandName, subcommand))
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

    private func runSubrouterCredits(commandName: String, commandArgs: [String], jsonOutput: Bool) async throws {
        let (tokenOpt, afterToken) = parseOption(commandArgs, name: "--token")
        let (controlPlaneURLOpt, afterControlPlaneURL) = parseOption(afterToken, name: "--control-plane-url")
        let (useHosted, remaining) = removeSubrouterFlag(afterControlPlaneURL, name: "--hosted")
        if useHosted && controlPlaneURLOpt != nil {
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.usageCredits, commandName))
        }
        try rejectUnexpectedSubrouterArguments(remaining, commandName: commandName, subcommand: "credits")

        let environment = ProcessInfo.processInfo.environment
        let authToken = tokenOpt ?? environment["CODEX_AUTH_TOKEN"]
        guard let authToken, !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.creditsMissingToken, commandName))
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
        let result = try await fetchSubrouterRateLimitResetCredits(url: creditsURL, authToken: authToken)

        if jsonOutput {
            print(jsonString(result))
            return
        }

        guard let wrapper = result["rate_limit_reset_credits"] as? [String: Any],
              let availableCount = wrapper["available_count"] as? Int,
              let credits = wrapper["credits"] as? [[String: Any]] else {
            throw CLIError(message: SubrouterText.creditsUnexpectedResponse)
        }

        print(SubrouterText.creditsTitle)
        print(String.localizedStringWithFormat(SubrouterText.creditsAvailable, availableCount))
        if credits.isEmpty {
            print(SubrouterText.creditsNone)
        } else {
            print(SubrouterText.creditsHeader)
            for credit in credits {
                let id = credit["id"] as? String ?? SubrouterText.creditsUnknownID
                let status = credit["status"] as? String ?? SubrouterText.creditsUnknownStatus
                let title = credit["title"] as? String ?? SubrouterText.creditsDefaultTitle
                let consumedMarker = status == "available" ? SubrouterText.creditsNotConsumed : SubrouterText.creditsConsumed
                print(String.localizedStringWithFormat(SubrouterText.creditsItem, id, title, status, consumedMarker))
            }
        }
    }

    private func fetchSubrouterRateLimitResetCredits(url: String, authToken: String) async throws -> [String: Any] {
        guard let requestURL = URL(string: url) else {
            throw CLIError(message: String.localizedStringWithFormat(SubrouterText.creditsInvalidURL, url))
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

        do {
            let (data, response) = try await session.data(for: request)
            guard !data.isEmpty else {
                throw CLIError(message: SubrouterText.creditsNoData)
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CLIError(message: SubrouterText.creditsNonHTTP)
            }
            guard httpResponse.statusCode == 200 else {
                throw CLIError(message: String.localizedStringWithFormat(SubrouterText.creditsHTTPStatus, httpResponse.statusCode))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dictionary = object as? [String: Any] else {
                throw CLIError(message: SubrouterText.creditsInvalidJSON)
            }
            return dictionary
        } catch let error as URLError where error.code == .timedOut {
            throw CLIError(message: SubrouterText.creditsTimeout)
        }
    }
}
