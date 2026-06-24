import CMUXAgentLaunch
import Foundation

/// Resolves whether a Claude config directory is configured for resume, against a
/// constructor-injected `FileManager` so the probe is testable with a scoped filesystem.
///
/// Replaces a caseless static-method namespace: the `FileManager` dependency is now
/// injected at construction instead of defaulted on each call.
public struct ClaudeConfigurationRoot {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// The preferred resume config directory for `configDir`, or `nil` when the
    /// resolved directory is not configured with usable Claude auth.
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

    /// Whether `configDir` contains a `.claude.json` with a usable auth value.
    public func isLikelyConfigured(_ configDir: String) -> Bool {
        let configPath = ((configDir as NSString).expandingTildeInPath as NSString)
            .appendingPathComponent(".claude.json")
        guard let data = fileManager.contents(atPath: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return Self.hasConfiguredAuthValue(obj["oauthAccount"])
            || Self.hasConfiguredAuthValue(obj["primaryApiKey"])
            || Self.hasConfiguredAuthValue(obj["apiKey"])
    }

    private static func hasConfiguredAuthValue(_ value: Any?) -> Bool {
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
