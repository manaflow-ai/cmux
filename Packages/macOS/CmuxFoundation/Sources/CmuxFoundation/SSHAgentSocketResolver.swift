import Foundation

/// Resolves OpenSSH option values that influence local SSH agent socket usage.
///
/// Use this type when code needs to interpret `ForwardAgent` or inspect
/// OpenSSH-style `-o key=value` arguments without depending on app-level remote
/// workspace types.
public struct SSHAgentSocketResolver: Sendable {
    /// The environment used when a `ForwardAgent` value references `$SSH_AUTH_SOCK` or another variable.
    public let environment: [String: String]

    /// Creates a resolver that reads agent socket references from the current process environment.
    public init() {
        self.init(environment: ProcessInfo.processInfo.environment)
    }

    /// Creates a resolver that reads agent socket references from an environment snapshot.
    ///
    /// - Parameter environment: Environment variables visible to the OpenSSH process.
    public init(environment: [String: String]) {
        self.environment = environment
    }

    /// Returns the lowercased key from an OpenSSH-style option string.
    ///
    /// - Parameter option: An option such as `ForwardAgent=yes` or `ForwardAgent yes`.
    /// - Returns: The normalized option key, or `nil` when the option has no key.
    public func optionKey(_ option: String) -> String? {
        parsedOption(option)?.key
    }

    /// Reads the first non-empty value for an OpenSSH-style option.
    ///
    /// OpenSSH keeps the first value obtained for command-line configuration,
    /// so later duplicate `-o` values do not override the first.
    ///
    /// - Parameters:
    ///   - key: The option key to read.
    ///   - options: Option strings such as `ForwardAgent=yes`.
    /// - Returns: The first non-empty matching option value, or `nil`.
    public func optionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options {
            if let parsed = parsedOption(option),
               parsed.key == loweredKey,
               let value = parsed.value {
                return value
            }
        }
        return nil
    }

    /// Parses the key and optional value forms accepted by OpenSSH's `-o` argument.
    private func parsedOption(_ option: String) -> (key: String, value: String?)? {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let separator = trimmed.firstIndex(where: { $0 == "=" || $0.isWhitespace }) else {
            return (trimmed.lowercased(), nil)
        }

        let key = trimmed[..<separator]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !key.isEmpty else { return nil }

        var value = trimmed[separator...]
        value = value.drop(while: { $0.isWhitespace })
        if value.first == "=" {
            value = value.dropFirst()
        }
        let rawValue = value
            .drop(while: { $0.isWhitespace })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return (key, nil) }

        let normalizedValue: String
        if rawValue.count >= 2,
           let quote = rawValue.first,
           (quote == "\"" || quote == "'"),
           rawValue.last == quote {
            normalizedValue = String(rawValue.dropFirst().dropLast())
        } else {
            normalizedValue = rawValue
        }
        guard !normalizedValue.isEmpty else { return (key, nil) }
        return (key, normalizedValue)
    }

    /// Returns whether an option list contains a key.
    ///
    /// - Parameters:
    ///   - options: Option strings to inspect.
    ///   - key: The key to match case-insensitively.
    /// - Returns: `true` when any option has the requested key.
    public func hasOptionKey(_ options: [String], key: String) -> Bool {
        let loweredKey = key.lowercased()
        return options.contains { option in
            optionKey(option) == loweredKey
        }
    }

    /// Removes all options with the requested key.
    ///
    /// - Parameters:
    ///   - key: The option key to remove.
    ///   - options: Option strings to filter.
    /// - Returns: The options whose key does not match `key`.
    public func removingOptions(named key: String, from options: [String]) -> [String] {
        let loweredKey = key.lowercased()
        return options.filter { option in
            optionKey(option) != loweredKey
        }
    }

    /// Returns SSH options that disable PTY allocation for a non-interactive lane.
    ///
    /// Removing caller and host-provided ``RequestTTY`` values and appending a
    /// command-line `no` override prevents OpenSSH configuration from
    /// re-enabling a PTY. Mosh management and SCP both use this policy, while
    /// their separately built interactive SSH paths retain the caller's intent.
    ///
    /// - Parameter options: OpenSSH-style options used by a non-interactive lane.
    /// - Returns: The options with one effective `RequestTTY=no` override.
    public func nonInteractiveOptions(from options: [String]) -> [String] {
        removingOptions(named: "RequestTTY", from: options) + ["RequestTTY=no"]
    }

    /// Returns SSH options for Mosh's non-PTY management connections.
    ///
    /// Mosh allocates the interactive terminal itself; this compatibility
    /// wrapper preserves the existing API while sharing the generic
    /// non-interactive policy with SCP.
    ///
    /// - Parameter options: OpenSSH-style options used by a Mosh management lane.
    /// - Returns: The options with one effective `RequestTTY=no` override.
    public func moshManagementOptions(from options: [String]) -> [String] {
        nonInteractiveOptions(from: options)
    }

    /// Normalizes a candidate SSH agent socket path and expands `~`.
    ///
    /// - Parameter value: A raw socket path value.
    /// - Returns: A trimmed, tilde-expanded path, or `nil` for empty input.
    public func normalizedAgentSocketPath(_ value: String?) -> String? {
        guard let trimmed = normalizedOptional(value) else { return nil }
        guard trimmed.hasPrefix("~") else { return trimmed }
        return normalizedOptional((trimmed as NSString).expandingTildeInPath) ?? trimmed
    }

    /// Resolves the effective `ForwardAgent` option into an agent socket path candidate.
    ///
    /// - Parameter options: OpenSSH-style option strings.
    /// - Returns: A socket path candidate, or `nil` when no usable `ForwardAgent` value exists.
    public func agentSocketPath(for options: [String]) -> String? {
        guard let forwardAgentValue = optionValue(named: "ForwardAgent", in: options) else {
            return nil
        }
        return agentSocketPath(forForwardAgentValue: forwardAgentValue)
    }

    /// Resolves a `ForwardAgent` value into an agent socket path candidate.
    ///
    /// Supported values are boolean yes-like values, `$VARIABLE` references,
    /// and literal absolute or tilde-prefixed socket paths. No-like values and
    /// `ask` do not identify a socket by themselves.
    ///
    /// - Parameter value: The `ForwardAgent` value to resolve.
    /// - Returns: A normalized socket path candidate, or `nil`.
    public func agentSocketPath(forForwardAgentValue value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$") {
            let variableName = String(trimmed.dropFirst())
            return normalizedAgentSocketPath(environment[variableName])
        }
        if Self.isSSHYesValue(trimmed) {
            return normalizedAgentSocketPath(environment["SSH_AUTH_SOCK"])
        }
        guard !Self.isSSHNoValue(trimmed),
              Self.isPathLikeSSHAgentSocketValue(trimmed) else {
            return nil
        }
        return normalizedAgentSocketPath(trimmed)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isSSHYesValue(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "true", "on", "1":
            return true
        default:
            return false
        }
    }

    private static func isSSHNoValue(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "no", "false", "off", "0", "ask":
            return true
        default:
            return false
        }
    }

    private static func isPathLikeSSHAgentSocketValue(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("~")
    }
}
