/// Builds the CodeRouter child arguments and filtered environment.
public struct CodeRouterLaunchPolicy {
    /// Creates a CodeRouter launch policy.
    public init() {}

    /// Tests whether a command needs the native cmux handoff.
    ///
    /// - Parameter commandArgs: The exact CodeRouter arguments.
    /// - Returns: `true` only for the supported provider commands.
    public func commandRequiresHandoff(_ commandArgs: [String]) -> Bool {
        commandArgs.first.map { ["codex", "opencode", "pi"].contains($0) }
            ?? false
    }

    /// Builds the fail-closed hidden CodeRouter argument form.
    ///
    /// - Parameters:
    ///   - commandArgs: The original provider command and arguments.
    ///   - handoff: The verified arm result, or `nil` for a management command.
    /// - Returns: The exact arguments for the CodeRouter process.
    public func launchArguments(
        commandArgs: [String],
        handoff: CodeRouterHandoffProtocol.Arm?
    ) -> [String] {
        guard let handoff else { return commandArgs }
        return [
            "__cmux-handoff-v2",
            handoff.socketPath,
            handoff.teamBinding,
            "--",
        ] + commandArgs
    }

    /// Filters the environment that enters the CodeRouter process.
    ///
    /// `PATH` stays because CodeRouter must select the user's provider
    /// executable. Routed commands remove credentials and network trust
    /// overrides. The `naked` command keeps provider credentials but still
    /// removes cmux control authority and loader injection variables.
    ///
    /// - Parameters:
    ///   - inheritedEnvironment: The parent process environment.
    ///   - forHandoff: Whether this launch will receive a native handoff.
    ///   - preserveProviderCredentials: Whether an explicit `naked` launch
    ///     keeps provider credentials.
    /// - Returns: The environment for the CodeRouter process.
    public func childEnvironment(
        _ inheritedEnvironment: [String: String],
        forHandoff: Bool,
        preserveProviderCredentials: Bool = false
    ) -> [String: String] {
        inheritedEnvironment.filter { key, _ in
            let normalized = key.uppercased()
            guard normalized != "CMUX",
                  !normalized.hasPrefix("CMUX_"),
                  normalized != "CMUXD",
                  !normalized.hasPrefix("CMUXD_"),
                  !normalized.hasPrefix("DYLD_"),
                  !normalized.hasPrefix("CODEROUTER_HANDOFF_"),
                  !normalized.hasPrefix("CODEROUTER_CMUX_HANDOFF_") else {
                return false
            }
            if !preserveProviderCredentials,
               normalized.hasPrefix("CI_JOB_JWT")
                   || normalized == "AWS_ACCESS_KEY_ID"
                   || normalized == "NPM_CONFIG__AUTH"
                   || normalized == "NPM_TOKEN"
                   || normalized == "DOCKER_AUTH_CONFIG"
                   || shouldScrubEnvironmentKey(key) {
                return false
            }
            if forHandoff,
               normalized == "CODEROUTER_API_URL"
                   || normalized == "CODEROUTER_DATA_DIR" {
                return false
            }
            if forHandoff, shouldScrubHandoffNetworkKey(normalized) {
                return false
            }
            return true
        }
    }

    private func shouldScrubHandoffNetworkKey(
        _ normalizedKey: String
    ) -> Bool {
        switch normalizedKey {
        case "HTTP_PROXY",
             "HTTPS_PROXY",
             "ALL_PROXY",
             "NO_PROXY",
             "SSL_CERT_FILE",
             "SSL_CERT_DIR",
             "SSLKEYLOGFILE",
             "CURL_CA_BUNDLE",
             "REQUESTS_CA_BUNDLE":
            true
        default:
            false
        }
    }

    private func shouldScrubEnvironmentKey(_ key: String) -> Bool {
        let normalized = key.uppercased()
        switch normalized {
        case "STACK_ACCESS_TOKEN", "STACK_REFRESH_TOKEN", "OPENAI_API_KEY",
             "GITHUB_PAT", "GITHUB_TOKEN":
            return true
        default:
            break
        }

        if normalized.contains("TOKEN")
            || normalized.contains("SECRET")
            || normalized.contains("PASSWORD")
            || normalized.contains("API_KEY")
            || normalized.contains("APIKEY")
            || normalized.contains("PRIVATE_KEY")
            || normalized.contains("CREDENTIAL")
            || normalized.hasSuffix("_KEY")
            || normalized.hasSuffix("_PAT") {
            return true
        }
        return false
    }
}
