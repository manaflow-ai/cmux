import Foundation

// Claude Code without a Claude sign-in of its own (hq#2569 #2): what else it
// reads to reach a model, the way acpmux's `claude_auth.rs` finds it. Names
// and presence only, never a value.
extension ProviderDetector {
    /// Variables that carry a Claude Code credential by themselves.
    static let claudeTokenKeys = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"]
    /// Switches to a cloud provider whose credentials Claude Code does not keep.
    static let claudeCloudSwitches = ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"]
    /// Settings that make Claude Code fetch its own credential.
    static let claudeHelpers = ["apiKeyHelper", "awsCredentialExport", "awsAuthRefresh"]
    static let claudeManagedSettings = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")

    /// The first of, in order: a token or cloud switch in the environment
    /// (the login shell's, so `.zshenv` exports count); a token or switch in
    /// the `env` of the managed or the Claude home's settings, or a helper
    /// there (sr writes `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` into
    /// `settings.json`); an API key `/login` saved in `.claude.json`. The
    /// row's detail names the setting a file holds.
    func detectClaudeConfigured(configDir: URL) -> ProviderDetection? {
        if let key = Self.claudeTokenKeys.first(where: { environment.value($0) != nil })
            ?? Self.claudeCloudSwitches.first(where: { Self.truthy(environment.value($0)) }) {
            return ProviderDetection(provider: .claude, status: .signedIn, sources: [.environment(key)])
        }
        let settings = [Self.claudeManagedSettings, configDir.appendingPathComponent("settings.json")]
        for file in settings {
            guard let root = environment.jsonObject(at: file) else { continue }
            let env = root["env"] as? [String: Any] ?? [:]
            let key = Self.claudeTokenKeys.first { Self.nonEmpty(env[$0]) }
                ?? Self.claudeCloudSwitches.first { Self.truthy(Self.text(env[$0])) }
                ?? Self.claudeHelpers.first { Self.nonEmpty(root[$0]) }
            if let key {
                return ProviderDetection(provider: .claude, status: .signedIn, detail: key, sources: [.file(environment.display(file))])
            }
        }
        let saved = environment.value("CLAUDE_CONFIG_DIR") != nil
            ? configDir.appendingPathComponent(".claude.json")
            : environment.home.appendingPathComponent(".claude.json")
        if Self.nonEmpty(environment.jsonObject(at: saved)?["primaryApiKey"]) {
            return ProviderDetection(provider: .claude, status: .signedIn, sources: [.file(environment.display(saved))], note: .savedAPIKey)
        }
        return nil
    }

    /// A switch is on unless empty, `0` or `false` (Claude Code's reading).
    static func truthy(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
        return value != "0" && value.lowercased() != "false"
    }

    /// A settings value as text: a string, a number or a boolean.
    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
