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

    /// Discovers or augments the curated list for one provider.
    ///
    /// Only OpenCode executes a CLI. Codex and Claude read their configuration
    /// files and prepend a configured model when one is available.
    ///
    /// - Parameter provider: Provider whose model list is requested.
    /// - Returns: Models plus the strategy source.
    public func models(
        for provider: MobileTaskModelProvider
    ) async -> MobileTaskModelListResult {
        switch provider {
        case .openCode:
            let output = await commandRunner("opencode models", .seconds(5))
            let ids = output.map(parser.openCodeModelIDs(from:)) ?? []
            guard !ids.isEmpty else {
                return fallback(for: provider)
            }
            return MobileTaskModelListResult(
                models: ids.map {
                    MobileTaskModel(
                        id: $0,
                        displayName: provider.displayName(for: $0)
                    )
                },
                source: .discovered
            )
        case .codex:
            let url = homeDirectory
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("config.toml")
            let configured = await fileReader(url)
                .flatMap(parser.codexConfiguredModel(from:))
            return augmented(configuredModel: configured, for: provider)
        case .claude:
            let url = homeDirectory
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json")
            let configured = await fileReader(url)
                .flatMap(parser.claudeConfiguredModel(from:))
            return augmented(configuredModel: configured, for: provider)
        }
    }

    private func fallback(
        for provider: MobileTaskModelProvider
    ) -> MobileTaskModelListResult {
        MobileTaskModelListResult(
            models: provider.curatedModels,
            source: .fallback
        )
    }

    private func augmented(
        configuredModel: String?,
        for provider: MobileTaskModelProvider
    ) -> MobileTaskModelListResult {
        guard let configuredModel else { return fallback(for: provider) }
        let configured = MobileTaskModel(
            id: configuredModel,
            displayName: provider.displayName(for: configuredModel)
        )
        return MobileTaskModelListResult(
            models: [configured] + provider.curatedModels.filter {
                $0.id != configuredModel
            },
            source: .augmented
        )
    }
}
