public import Foundation

/// Provider-specific model discovery with injected process and filesystem I/O.
public struct MobileTaskModelProviderStrategy: Sendable {
    /// Runs one login-shell command under a bounded timeout.
    public typealias CommandRunner = @Sendable (
        _ command: String,
        _ timeout: Duration
    ) async -> String?
    /// Reads one configuration file without blocking the caller's executor.
    public typealias FileReader = @Sendable (_ url: URL) async -> Data?

    private let homeDirectory: URL
    private let environment: [String: String]
    private let commandRunner: CommandRunner
    private let fileReader: FileReader
    private let parser: MobileTaskModelParser

    /// Creates a provider strategy.
    ///
    /// - Parameters:
    ///   - homeDirectory: User home containing provider configuration.
    ///   - environment: Environment the provider runs in. Codex honors
    ///     `CODEX_HOME` and the cmux `CMUX_CUSTOM_CODEX_PATH` executable.
    ///   - commandRunner: Injected bounded login-shell command runner.
    ///   - fileReader: Injected asynchronous file reader.
    ///   - parser: Pure provider-output parser.
    public init(
        homeDirectory: URL,
        environment: [String: String] = [:],
        commandRunner: @escaping CommandRunner,
        fileReader: @escaping FileReader,
        parser: MobileTaskModelParser = MobileTaskModelParser()
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.commandRunner = commandRunner
        self.fileReader = fileReader
        self.parser = parser
    }

    /// Discovers the models exposed by the provider installed on this Mac.
    ///
    /// Claude answers a control-stream `list_models` request, Codex exposes a
    /// local debug catalog with an owned cache fallback, and OpenCode exposes
    /// `opencode models`. No product-owned list participates in this result.
    ///
    /// - Parameter provider: Provider whose model list is requested.
    /// - Returns: Models plus the strategy source.
    public func models(
        for provider: MobileTaskModelProvider
    ) async -> MobileTaskModelListResult {
        switch provider {
        case .openCode:
            // OpenCode resolves installed provider authentication before it
            // prints the catalog. A cold invocation commonly exceeds five
            // seconds, while the result is cached above this strategy.
            let output = await commandRunner("opencode models --verbose", .seconds(30))
            let models = output.map(parser.openCodeModels(from:)) ?? []
            guard !models.isEmpty else {
                return await failedDiscovery(
                    for: provider,
                    commandReturnedOutput: output != nil
                )
            }
            return discovered(models)
        case .codex:
            let output = await commandRunner(codexModelsCommand, .seconds(5))
            let discoveredModels = output.map(parser.codexModels(from:)) ?? []
            if !discoveredModels.isEmpty {
                return discovered(
                    discoveredModels,
                    defaultModel: await codexDefaultModel(in: discoveredModels)
                )
            }
            let url = codexHomeDirectory
                .appendingPathComponent("models_cache.json")
            let models = await fileReader(url)
                .map(parser.codexModels(from:)) ?? []
            let defaultModel = await codexDefaultModel(in: models)
            guard !models.isEmpty else {
                return await failedDiscovery(
                    for: provider,
                    commandReturnedOutput: output != nil
                )
            }
            return discovered(models, defaultModel: defaultModel)
        case .claude:
            let output = await commandRunner(
                Self.claudeModelListCommand,
                .seconds(30)
            )
            let models = output.map(parser.claudeModels(from:)) ?? []
            let defaultModel = output.flatMap(parser.claudeDefaultModel(from:))
            guard !models.isEmpty || defaultModel != nil else {
                return await failedDiscovery(
                    for: provider,
                    commandReturnedOutput: output != nil
                )
            }
            return discovered(models, defaultModel: defaultModel)
        }
    }

    private func failedDiscovery(
        for provider: MobileTaskModelProvider,
        commandReturnedOutput: Bool
    ) async -> MobileTaskModelListResult {
        let error: MobileTaskModelListError
        if commandReturnedOutput {
            error = .queryFailed
        } else {
            let executable = provider == .codex
                ? codexExecutable
                : provider.rawValue
            let availability = await commandRunner(
                "command -v \(executable)",
                .seconds(2)
            )
            error = availability == nil ? .providerUnavailable : .queryFailed
        }
        return MobileTaskModelListResult(
            models: [],
            source: .fallback,
            error: error
        )
    }

    private func discovered(
        _ models: [MobileTaskModel],
        defaultModel: MobileTaskModel? = nil
    ) -> MobileTaskModelListResult {
        MobileTaskModelListResult(
            models: models,
            source: models.isEmpty && defaultModel == nil ? .fallback : .discovered,
            defaultModel: defaultModel
        )
    }

    private func codexDefaultModel(
        in models: [MobileTaskModel]
    ) async -> MobileTaskModel? {
        guard !models.isEmpty else { return nil }
        let url = codexHomeDirectory
            .appendingPathComponent("config.toml")
        guard let data = await fileReader(url),
              let configuredID = parser.codexConfiguredModel(from: data) else {
            return nil
        }
        return models.first { $0.id == configuredID }
    }

    private var codexModelsCommand: String {
        let command = "exec \(codexExecutable) debug models"
        // Pin the home the fallback files are read from, so a login-shell
        // profile cannot point the command at a different account.
        guard nonEmptyEnvironmentValue("CODEX_HOME") != nil else {
            return command
        }
        return "CODEX_HOME=\(Self.shellQuoted(codexHomeDirectory.path)) \(command)"
    }

    /// Shell token for the Codex executable cmux sessions launch.
    private var codexExecutable: String {
        nonEmptyEnvironmentValue("CMUX_CUSTOM_CODEX_PATH").map(Self.shellQuoted) ?? "codex"
    }

    /// Codex state directory, following `CODEX_HOME` like the Codex CLI.
    private var codexHomeDirectory: URL {
        guard let codexHome = nonEmptyEnvironmentValue("CODEX_HOME") else {
            return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }
        let path: String
        if codexHome == "~" {
            path = homeDirectory.path
        } else if codexHome.hasPrefix("~/") {
            path = homeDirectory.path + "/" + codexHome.dropFirst(2)
        } else {
            path = codexHome
        }
        return URL(fileURLWithPath: path, isDirectory: true, relativeTo: homeDirectory)
            .standardizedFileURL
    }

    private func nonEmptyEnvironmentValue(_ key: String) -> String? {
        guard let value = environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static let claudeModelListCommand = #"""
    set -o pipefail
    /usr/bin/printf '%s\n' '{"type":"control_request","request_id":"cmux-list-options","request":{"subtype":"list_models"}}' | /usr/bin/env CLAUDE_CODE_ENTRYPOINT=cmux-task-models claude -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose
    """#
}
