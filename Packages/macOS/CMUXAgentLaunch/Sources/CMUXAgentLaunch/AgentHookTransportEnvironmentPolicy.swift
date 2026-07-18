import Foundation

/// Selects routing and auto-naming inputs that may cross the agent-hook boundary.
///
/// The native sender, portable CLI fallback, app-side decoder, and legacy queue
/// migration share this policy so a value cannot become durable through a
/// different admission path.
public struct AgentHookTransportEnvironmentPolicy: Sendable {
    private static let launchArgumentsKey = "CMUX_AGENT_LAUNCH_ARGV_B64"
    private static let maximumLaunchArgumentsBytes = 128 * 1024

    /// Per-attempt capabilities and ownership markers must never cross a retry
    /// or app-process boundary. The supervisor PID is injected only by the
    /// live supervisor immediately before it execs the delivery child.
    private static let transportOnlyKeys: Set<String> = [
        "CMUX_AGENT_HOOK_DELIVERY_ID",
        "CMUX_AGENT_HOOK_DELIVERY_PROCESS_GROUP",
        "CMUX_AGENT_HOOK_DELIVERY_SUPERVISOR_PID",
        "CMUX_SOCKET_CAPABILITY",
    ]

    private static let coreKeys: Set<String> = [
        "HOME", "PATH", "PWD", "TMPDIR", "TMP", "TEMP",
        "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE",
        "CODEX_HOME",
        "CMUX_AGENT_HOOK_STATE_DIR",
        "CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS",
        launchArgumentsKey,
        "CMUX_AGENT_LAUNCH_CWD",
        "CMUX_AGENT_LAUNCH_EXECUTABLE",
        "CMUX_AGENT_LAUNCH_KIND",
        "CMUX_AGENT_MANAGED_SUBAGENT",
        "CMUX_BUNDLE_ID",
        "CMUX_CODEX_PID",
        "CMUX_CUSTOM_CLAUDE_PATH",
        "CMUX_SOCKET_PATH",
        "CMUX_SUPPRESS_SUBAGENT_NOTIFICATIONS",
        "CMUX_SURFACE_ID",
        "CMUX_TAG",
        "CMUX_WORKSPACE_ID",
    ]

    private static let autoNamingExactKeys: Set<String> = [
        "ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
        "all_proxy", "https_proxy", "http_proxy", "no_proxy",
        "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "SSL_CERT_DIR", "SSL_CERT_FILE",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
    ]

    /// These keys name files rather than carrying the credentials in those files.
    /// The value must also pass the path-shape check before becoming durable.
    private static let durableCredentialFileLocatorKeys: Set<String> = [
        "AWS_CONFIG_FILE",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
        "AWS_SHARED_CREDENTIALS_FILE",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
        "GOOGLE_APPLICATION_CREDENTIALS",
    ]

    /// Container URI paths are bearer capabilities even when they contain no
    /// query parameter or authorization-looking key name.
    private static let alwaysEphemeralKeys: Set<String> = [
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
    ]

    private static let proxyURLKeys: Set<String> = [
        "ALL_PROXY", "HTTPS_PROXY", "HTTP_PROXY",
        "all_proxy", "https_proxy", "http_proxy",
    ]

    /// Provider families accepted for live auto-naming. Unknown values in these
    /// families stay memory-only unless a durable category below recognizes them.
    private static let autoNamingPrefixes = [
        "ANTHROPIC_", "AWS_", "CLOUD_ML_", "GCLOUD_", "GEMINI_", "GOOGLE_",
        "OPENAI_", "OPENROUTER_", "XAI_",
    ]

    /// Generic provider adapters use these names even when cmux does not know
    /// the provider prefix ahead of time.
    private static let autoNamingSuffixes = [
        "_ACCESS_TOKEN", "_API_KEY", "_AUTH_TOKEN", "_CLIENT_SECRET",
        "_API_URL", "_BASE_URL", "_MODEL",
    ]

    private static let knownDurableProviderScalarKeys: Set<String> = [
        "AWS_DEFAULT_PROFILE",
        "AWS_DEFAULT_REGION",
        "AWS_EC2_METADATA_DISABLED",
        "AWS_PROFILE",
        "AWS_REGION",
        "AWS_ROLE_ARN",
        "AWS_ROLE_SESSION_NAME",
        "AWS_SDK_LOAD_CONFIG",
        "CLOUD_ML_REGION",
        "GCLOUD_PROJECT",
        "GOOGLE_CLOUD_PROJECT",
        "GOOGLE_CLOUD_QUOTA_PROJECT",
        "OPENAI_ORGANIZATION",
        "OPENAI_ORG_ID",
    ]

    private static let credentialFragments = [
        "ACCESS_KEY", "ACCESS_TOKEN", "API_KEY", "AUTH_TOKEN", "CLIENT_SECRET",
        "CREDENTIAL", "PASSWORD", "PRIVATE_KEY", "SECRET", "SESSION_TOKEN",
    ]

    private static let credentialKeyComponents: Set<Substring> = [
        "AUTH", "AUTHORIZATION", "BEARER", "CREDENTIAL", "CREDENTIALS",
        "JWT", "KEY", "PASSWORD", "SECRET", "SIGNATURE", "SIGNED", "TOKEN",
    ]

    private static let endpointSchemes: Set<String> = [
        "grpc", "grpcs", "http", "https", "ws", "wss",
    ]

    private static let proxySchemes: Set<String> = [
        "http", "https", "socks", "socks4", "socks4a", "socks5", "socks5h",
    ]

    private static let replaySafeEnvironmentKeys = AgentLaunchEnvironmentPolicy.replaySafeEnvironmentKeys

    /// Creates a hook transport environment policy.
    public init() {}

    /// Partitions selected hook values into durable and memory-only dictionaries.
    ///
    /// - Parameters:
    ///   - environment: The hook process environment to classify.
    ///   - hookAgentKind: The validated agent that emitted the hook.
    /// - Returns: Values selected for durable recovery and live-only delivery.
    public func partitionedEnvironment(
        from environment: [String: String],
        hookAgentKind: String
    ) -> AgentHookTransportEnvironment {
        var durable: [String: String] = [:]
        var ephemeral: [String: String] = [:]
        durable.reserveCapacity(environment.count)
        ephemeral.reserveCapacity(8)

        for (key, rawValue) in environment {
            guard let value = selectedValue(key: key, value: rawValue) else { continue }
            let durableValue = durableValueForPersistence(
                key: key,
                value: value,
                environment: environment,
                hookAgentKind: hookAgentKind
            )

            if key == Self.launchArgumentsKey {
                // The exact argv remains available to lifecycle logic in the
                // current process. Only its replay-safe form crosses a crash.
                ephemeral[key] = value
                if let durableValue { durable[key] = durableValue }
            } else if let durableValue {
                durable[key] = durableValue
            } else {
                ephemeral[key] = value
            }
        }

        return AgentHookTransportEnvironment(durable: durable, ephemeral: ephemeral)
    }

    /// Returns the selected live-delivery environment.
    ///
    /// Memory-only values override sanitized durable fallbacks for the same key.
    ///
    /// - Parameters:
    ///   - environment: The hook process environment to classify.
    ///   - hookAgentKind: The agent that emitted the hook.
    public func selectedEnvironment(
        from environment: [String: String],
        hookAgentKind: String
    ) -> [String: String] {
        partitionedEnvironment(from: environment, hookAgentKind: hookAgentKind).merged
    }

    /// Scrubs an environment written by an older cmux before it remains durable.
    ///
    /// Unknown non-provider routing inputs are preserved. Credentials, provider
    /// values without a recognized durable shape, and untrusted raw launch argv
    /// are removed. Trusted argv is replaced with a replay-safe encoding.
    ///
    /// - Parameters:
    ///   - environment: A previously persisted hook environment.
    ///   - hookAgentKind: The validated agent stored with the queue row.
    public func durableEnvironmentForPersistence(
        from environment: [String: String],
        hookAgentKind: String
    ) -> [String: String] {
        var durable: [String: String] = [:]
        durable.reserveCapacity(environment.count)
        for (key, rawValue) in environment {
            guard let value = normalizedValueForPersistence(key: key, value: rawValue),
                  let persisted = durableValueForPersistence(
                      key: key,
                      value: value,
                      environment: environment,
                      hookAgentKind: hookAgentKind
                  ) else {
                continue
            }
            durable[key] = persisted
        }
        return durable
    }

    private func selectedValue(key: String, value: String) -> String? {
        guard Self.isSelectedKey(key) else { return nil }
        return normalizedValueForPersistence(key: key, value: value)
    }

    private func normalizedValueForPersistence(key: String, value: String) -> String? {
        if Self.replaySafeEnvironmentKeys.contains(key) {
            return AgentLaunchEnvironmentPolicy().sanitizedValue(key: key, value: value)
        }
        return value.isEmpty ? nil : value
    }

    private func durableValueForPersistence(
        key: String,
        value: String,
        environment: [String: String],
        hookAgentKind: String
    ) -> String? {
        if Self.transportOnlyKeys.contains(key) { return nil }
        if key == Self.launchArgumentsKey {
            return Self.sanitizedLaunchArgumentsEncoding(
                value,
                environment: environment,
                hookAgentKind: hookAgentKind
            )
        }
        if Self.alwaysEphemeralKeys.contains(key) { return nil }
        if Self.durableCredentialFileLocatorKeys.contains(key) {
            return Self.isSafeFileLocator(value) ? value : nil
        }
        if Self.isCredentialBearingKey(key) { return nil }
        if Self.isNetworkURLKey(key) {
            return Self.isCredentialFreeNetworkURL(value, forProxy: Self.proxyURLKeys.contains(key))
                ? value
                : nil
        }
        if Self.isProviderPrefixedKey(key) {
            guard Self.isKnownDurableProviderScalarKey(key),
                  Self.isSafeScalar(value) else {
                return nil
            }
        }
        return value
    }

    private static func isSelectedKey(_ key: String) -> Bool {
        replaySafeEnvironmentKeys.contains(key)
            || coreKeys.contains(key)
            || autoNamingExactKeys.contains(key)
            || isProviderPrefixedKey(key)
            || autoNamingSuffixes.contains(where: key.hasSuffix)
    }

    private static func isProviderPrefixedKey(_ key: String) -> Bool {
        autoNamingPrefixes.contains(where: key.hasPrefix)
    }

    private static func isKnownDurableProviderScalarKey(_ key: String) -> Bool {
        replaySafeEnvironmentKeys.contains(key)
            || autoNamingExactKeys.contains(key)
            || knownDurableProviderScalarKeys.contains(key)
            || key.hasSuffix("_MODEL")
    }

    private static func isCredentialBearingKey(_ key: String) -> Bool {
        let normalized = key.uppercased()
        if credentialFragments.contains(where: normalized.contains) { return true }
        let components = normalized.split { character in
            !character.isLetter && !character.isNumber
        }
        return !credentialKeyComponents.isDisjoint(with: components)
    }

    private static func isNetworkURLKey(_ key: String) -> Bool {
        if proxyURLKeys.contains(key) { return true }
        let components = key.uppercased().split { character in
            !character.isLetter && !character.isNumber
        }
        return components.contains("URL")
            || components.contains("URI")
            || components.contains("ENDPOINT")
    }

    private static func isCredentialFreeNetworkURL(_ value: String, forProxy: Bool) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
                      || CharacterSet.whitespacesAndNewlines.contains(scalar)
              }),
              hasOnlyValidPercentEscapes(value),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              (forProxy ? proxySchemes : endpointSchemes).contains(scheme),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        return true
    }

    private static func hasOnlyValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%") {
                guard index + 2 < bytes.count,
                      isHexDigit(bytes[index + 1]),
                      isHexDigit(bytes[index + 2]) else {
                    return false
                }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func isHexDigit(_ value: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(value)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(value)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(value)
    }

    private static func isSafeFileLocator(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !looksLikeCredentialBlob(value) else {
            return false
        }
        return value.hasPrefix("/")
            || value.hasPrefix("~/")
            || value.hasPrefix("./")
            || value.hasPrefix("../")
            || value.hasPrefix("$HOME/")
            || value.hasPrefix("${HOME}/")
    }

    private static func isSafeScalar(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !looksLikeCredentialBlob(value)
    }

    private static func looksLikeCredentialBlob(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{")
            || trimmed.hasPrefix("[")
            || trimmed.hasPrefix("-----BEGIN ")
            || value.contains("\n")
            || value.contains("\r") {
            return true
        }
        guard trimmed.utf8.count <= maximumLaunchArgumentsBytes,
              let decoded = Data(base64Encoded: trimmed),
              let decodedText = String(data: decoded, encoding: .utf8) else {
            return false
        }
        let decodedTrimmed = decodedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return decodedTrimmed.hasPrefix("{")
            || decodedTrimmed.hasPrefix("[")
            || decodedTrimmed.hasPrefix("-----BEGIN ")
    }

    private static func sanitizedLaunchArgumentsEncoding(
        _ encoded: String,
        environment: [String: String],
        hookAgentKind: String
    ) -> String? {
        guard let arguments = decodeLaunchArguments(encoded),
              let normalizedHookKind = normalized(environmentValue: hookAgentKind) else {
            return nil
        }

        let sanitizerLauncher: String
        if let capturedLauncher = normalized(environmentValue: environment["CMUX_AGENT_LAUNCH_KIND"]) {
            guard AgentLaunchCaptureTrust.launcherDescribesKind(
                capturedLauncher,
                kind: normalizedHookKind
            ) else {
                return nil
            }
            sanitizerLauncher = canonicalLauncher(capturedLauncher, hookAgentKind: normalizedHookKind)
        } else {
            guard AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: nil,
                arguments: arguments,
                kind: normalizedHookKind
            ) else {
                return nil
            }
            sanitizerLauncher = normalizedHookKind
        }

        guard let sanitized = AgentLaunchSanitizer.sanitizedLaunchArguments(
            arguments,
            launcher: sanitizerLauncher,
            fallbackKind: normalizedHookKind,
            stripCmuxHookArguments: true
        ), !sanitized.isEmpty else {
            return nil
        }
        return encodeLaunchArguments(sanitized)
    }

    private static func canonicalLauncher(_ launcher: String, hookAgentKind: String) -> String {
        switch launcher.lowercased() {
        case hookAgentKind.lowercased():
            return hookAgentKind.lowercased()
        case "claudeteams":
            return "claudeTeams"
        case "codexteams":
            return "codexTeams"
        default:
            return launcher
        }
    }

    private static func decodeLaunchArguments(_ encoded: String) -> [String]? {
        guard encoded.utf8.count <= ((maximumLaunchArgumentsBytes + 2) / 3) * 4 + 4,
              let data = Data(base64Encoded: encoded),
              !data.isEmpty,
              data.count <= maximumLaunchArgumentsBytes else {
            return nil
        }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard !fields.isEmpty else { return nil }
        var arguments: [String] = []
        arguments.reserveCapacity(fields.count)
        for field in fields {
            guard !field.isEmpty,
                  let argument = String(data: field, encoding: .utf8) else {
                return nil
            }
            arguments.append(argument)
        }
        return arguments
    }

    private static func encodeLaunchArguments(_ arguments: [String]) -> String {
        var data = Data()
        for argument in arguments {
            data.append(contentsOf: argument.utf8)
            data.append(0)
        }
        return data.base64EncodedString()
    }

    private static func normalized(environmentValue: String?) -> String? {
        guard let value = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
