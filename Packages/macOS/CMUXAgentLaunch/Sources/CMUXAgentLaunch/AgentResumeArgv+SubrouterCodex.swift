import Foundation

extension AgentResumeArgv {
    /// The non-secret credential assignment required by Subrouter's custom Codex provider.
    public static let subrouterCodexDummyAPIKeyEnvironmentAssignment =
        "SUBROUTER_CODEX_DUMMY_API_KEY=subrouter"

    /// Returns Subrouter's dummy credential assignment when captured Codex config selects its env key.
    ///
    /// `subrouter codex` uses a custom provider whenever it needs request headers for account or model
    /// routing. The provider names a dummy environment variable because Codex requires custom providers
    /// to resolve an authentication source, while Subrouter replaces the outbound credential itself.
    /// Resume commands preserve the provider config arguments but cannot recover the launcher's process
    /// environment, so callers must restore this non-secret assignment alongside the preserved argv.
    ///
    /// - Parameter arguments: Captured or rendered Codex arguments containing `-c`/`--config` options.
    /// - Returns: The environment assignment when the effective Subrouter env-key config needs it.
    public func subrouterCodexDummyAPIKeyEnvironmentAssignment(
        in arguments: [String]
    ) -> String? {
        guard codexConfigValue(
            for: "model_providers.subrouter.env_key",
            in: arguments
        ) == "SUBROUTER_CODEX_DUMMY_API_KEY" else {
            return nil
        }
        return Self.subrouterCodexDummyAPIKeyEnvironmentAssignment
    }

    private func codexConfigValue(for key: String, in arguments: [String]) -> String? {
        var effectiveValue: String?
        for (index, argument) in arguments.enumerated() {
            let config: String?
            if argument == "-c" || argument == "--config" {
                config = index + 1 < arguments.count ? arguments[index + 1] : nil
            } else if argument.hasPrefix("-c=") {
                config = String(argument.dropFirst(3))
            } else if argument.hasPrefix("--config=") {
                config = String(argument.dropFirst(9))
            } else {
                config = nil
            }
            guard let config,
                  let assignment = codexConfigAssignment(config),
                  assignment.key == key else {
                continue
            }
            effectiveValue = unquotedCodexConfigValue(assignment.value)
        }
        return effectiveValue
    }

    private func codexConfigAssignment(_ config: String) -> (key: String, value: String)? {
        guard let separator = config.firstIndex(of: "=") else { return nil }
        let key = config[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let valueStart = config.index(after: separator)
        let value = config[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (key, value)
    }

    private func unquotedCodexConfigValue(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              first == value.last,
              first == "\"" || first == "'" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}
