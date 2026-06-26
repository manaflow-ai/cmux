import Foundation

/// Resolves ``InlineVSCodeServeWebOptions`` from cmux.json values, environment
/// variables, and internal defaults.
///
/// The environment and home directory are constructor-injected so resolution is
/// deterministic and testable. Precedence per field: cmux.json (`inlineVSCode.*`,
/// also written by the Settings UI) overrides the environment variable, which
/// overrides the internal default. The environment layer is a debugging escape
/// hatch; the Settings UI / `cmux.json` is the supported user-facing story.
struct InlineVSCodeServeWebOptionsResolver {
    /// Environment-variable names forming the fallback layer below cmux.json.
    static let portEnvironmentKey = "CMUX_INLINE_VSCODE_PORT"
    static let serverDataDirEnvironmentKey = "CMUX_INLINE_VSCODE_SERVER_DATA_DIR"
    static let persistStateEnvironmentKey = "CMUX_INLINE_VSCODE_PERSIST_STATE"
    static let extraArgsEnvironmentKey = "CMUX_INLINE_VSCODE_EXTRA_ARGS"

    let environment: [String: String]
    let homeDirectoryPath: String

    init(environment: [String: String], homeDirectoryPath: String) {
        self.environment = environment
        self.homeDirectoryPath = homeDirectoryPath
    }

    func resolve(file: InlineVSCodeConfigFileValues) -> InlineVSCodeServeWebOptions {
        InlineVSCodeServeWebOptions(
            port: resolvedPort(file: file.port),
            serverDataDir: resolvedServerDataDir(file: file.serverDataDir),
            persistServeWebState: file.persistServeWebState
                ?? Self.parseBool(environment[Self.persistStateEnvironmentKey])
                ?? InlineVSCodeServeWebOptions.default.persistServeWebState,
            extraArgs: resolvedExtraArgs(file: file.extraArgs)
        )
    }

    private func resolvedPort(file: Int?) -> Int {
        if let candidate = file ?? Self.parseInt(environment[Self.portEnvironmentKey]),
           (0...65535).contains(candidate) {
            return candidate
        }
        return InlineVSCodeServeWebOptions.default.port
    }

    private func resolvedServerDataDir(file: String?) -> String? {
        let raw = file ?? environment[Self.serverDataDirEnvironmentKey]
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return Self.expandingTilde(trimmed, homeDirectoryPath: homeDirectoryPath)
    }

    private func resolvedExtraArgs(file: [String]?) -> [String] {
        let raw: [String]
        if let file {
            raw = file
        } else if let env = environment[Self.extraArgsEnvironmentKey] {
            raw = env.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        } else {
            raw = []
        }
        return raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Expands a leading `~` / `~/` against `homeDirectoryPath`. Other paths are
    /// returned unchanged. Implemented against an injected home directory rather
    /// than `NSString.expandingTildeInPath` so resolution is deterministic in
    /// tests.
    static func expandingTilde(_ path: String, homeDirectoryPath: String) -> String {
        if path == "~" {
            return homeDirectoryPath
        }
        guard path.hasPrefix("~/") else {
            return path
        }
        let home = homeDirectoryPath.hasSuffix("/")
            ? String(homeDirectoryPath.dropLast())
            : homeDirectoryPath
        return home + String(path.dropFirst(1))
    }

    private static func parseInt(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return Int(value)
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        switch value {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}
