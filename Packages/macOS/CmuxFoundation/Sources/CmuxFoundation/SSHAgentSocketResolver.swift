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
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
            .split(whereSeparator: { $0 == "=" || $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
    }

    /// Reads the last non-empty value for an OpenSSH-style option.
    ///
    /// OpenSSH applies the last repeated `-o` value, so this method scans in
    /// reverse order.
    ///
    /// - Parameters:
    ///   - key: The option key to read.
    ///   - options: Option strings such as `ForwardAgent=yes`.
    /// - Returns: The last non-empty matching option value, or `nil`.
    public func optionValue(named key: String, in options: [String]) -> String? {
        let loweredKey = key.lowercased()
        for option in options.reversed() {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == "=" || $0.isWhitespace }
            )
            if parts.count == 2, parts[0].lowercased() == loweredKey {
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
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

    /// Normalizes a candidate SSH agent socket path and expands `~`.
    ///
    /// - Parameter value: A raw socket path value.
    /// - Returns: A trimmed, tilde-expanded path, or `nil` for empty input.
    public func normalizedAgentSocketPath(_ value: String?) -> String? {
        guard let trimmed = normalizedOptional(value) else { return nil }
        guard trimmed.hasPrefix("~") else { return trimmed }
        return normalizedOptional((trimmed as NSString).expandingTildeInPath) ?? trimmed
    }

    /// Resolves the last `ForwardAgent` option into an agent socket path candidate.
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
