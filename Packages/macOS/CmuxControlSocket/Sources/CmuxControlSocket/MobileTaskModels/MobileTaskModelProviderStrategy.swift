public import Foundation

/// Provider-specific model discovery with injected process and filesystem I/O.
public struct MobileTaskModelProviderStrategy: Sendable {
    private static let codexModelsCommand = "exec codex debug models"

    /// Runs one login-shell command under a bounded timeout.
    public typealias CommandRunner = @Sendable (
        _ command: String,
        _ timeout: Duration
    ) async -> String?
    /// Reads one configuration file without blocking the caller's executor.
    public typealias FileReader = @Sendable (_ url: URL) async -> Data?

    private let homeDirectory: URL
    private let commandRunner: CommandRunner
    private let fileReader: FileReader
    private let parser: MobileTaskModelParser

    /// Creates a provider strategy.
    ///
    /// - Parameters:
    ///   - homeDirectory: User home containing provider configuration.
    ///   - commandRunner: Injected bounded login-shell command runner.
    ///   - fileReader: Injected asynchronous file reader.
    ///   - parser: Pure provider-output parser.
    public init(
        homeDirectory: URL,
        commandRunner: @escaping CommandRunner,
        fileReader: @escaping FileReader,
        parser: MobileTaskModelParser = MobileTaskModelParser()
    ) {
        self.homeDirectory = homeDirectory
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
            let output = await commandRunner(Self.codexModelsCommand, .seconds(5))
            let discoveredModels = output.map(parser.codexModels(from:)) ?? []
            if !discoveredModels.isEmpty {
                return discovered(
                    discoveredModels,
                    defaultModel: await codexDefaultModel(in: discoveredModels)
                )
            }
            let url = homeDirectory
                .appendingPathComponent(".codex", isDirectory: true)
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
            let availability = await commandRunner(
                "command -v \(provider.rawValue)",
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
        let url = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml")
        guard let data = await fileReader(url),
              let configuredID = parser.codexConfiguredModel(from: data) else {
            return nil
        }
        return models.first { $0.id == configuredID }
    }

    private static let claudeModelListCommand = #"""
    set -o pipefail
    /usr/bin/printf '%s\n' '{"type":"control_request","request_id":"cmux-list-options","request":{"subtype":"list_models"}}' | /usr/bin/env CLAUDE_CODE_ENTRYPOINT=cmux-task-models claude -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose
    """#
}
