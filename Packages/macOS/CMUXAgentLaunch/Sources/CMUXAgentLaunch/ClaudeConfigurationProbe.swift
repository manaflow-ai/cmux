import Foundation

/// Probes a Claude Code config directory's `.claude.json` to decide whether the
/// account is configured (a non-empty OAuth account or API key is present) and,
/// when it is, resolves the resume config directory used to reopen a transcript.
///
/// A value type holding the injected ``FileManager`` it reads through, so tests
/// can probe a temporary directory and production reads `.default`. All reads are
/// pure filesystem probes with no mutable state.
public struct ClaudeConfigurationProbe {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The preferred resume config directory for `configDir`, or `nil` when the
    /// directory holds no configured Claude auth value.
    public func configuredResumeDirectory(_ configDir: String) -> String? {
        let preferredConfigDir = ClaudeConfigDirectoryPath.preferredPath(
            configDir,
            fileManager: fileManager
        )
        guard isLikelyConfigured(preferredConfigDir) else {
            return nil
        }
        return preferredConfigDir
    }

    /// Whether `configDir/.claude.json` carries a non-empty `oauthAccount`,
    /// `primaryApiKey`, or `apiKey` value.
    public func isLikelyConfigured(_ configDir: String) -> Bool {
        let configPath = ((configDir as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(".claude.json")
        guard let data = fileManager.contents(atPath: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return hasConfiguredAuthValue(obj["oauthAccount"])
            || hasConfiguredAuthValue(obj["primaryApiKey"])
            || hasConfiguredAuthValue(obj["apiKey"])
    }

    private func hasConfiguredAuthValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else {
            return false
        }
        if let string = value as? String {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let dictionary = value as? [String: Any] {
            return !dictionary.isEmpty
        }
        if let array = value as? [Any] {
            return !array.isEmpty
        }
        return true
    }
}
