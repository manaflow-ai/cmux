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

    func codexInstallation() async -> MobileTaskCodexInstallation? {
        await MobileTaskCodexInstallation.resolve(using: commandRunner, defaultHome: homeDirectory)
    }

    /// Discovers the models exposed by the provider installed on this Mac.
    ///
    /// Claude answers a control-stream `list_models` request, Codex exposes a
    /// local debug catalog with an owned cache fallback, and OpenCode exposes
    /// `opencode models`. No product-owned list participates in this result.
    ///
    /// - Parameters:
    ///   - provider: Provider whose model list is requested.
    ///   - claudeExecutable: Host-configured Claude executable, passed as one
    ///     shell argument. Defaults to login-shell lookup of claude and is
    ///     ignored for other providers.
    /// - Returns: Models plus the strategy source.
    public func models(
        for provider: MobileTaskModelProvider,
        claudeExecutable: String = "claude"
    ) async -> MobileTaskModelListResult {
        let installation = provider == .codex ? await codexInstallation() : nil
        return await models(
            for: provider,
            claudeExecutable: claudeExecutable,
            codexInstallation: installation
        )
    }

    func models(
        for provider: MobileTaskModelProvider,
        claudeExecutable: String,
        codexInstallation: MobileTaskCodexInstallation?
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
            guard let codexInstallation else {
                return MobileTaskModelListResult(models: [], source: .fallback, error: .queryFailed)
            }
            let codexHome = codexInstallation.home
            let executable = Self.shellArgument(codexInstallation.executable)
            let environment = Self.shellArgument("CODEX_HOME=" + codexHome.path)
            // env interprets any operand containing "=" as another assignment until the command.
            let command = #"exec /usr/bin/env \#(environment) /bin/sh -c 'exec "$0" debug models' \#(executable)"#
            let output = await commandRunner(command, .seconds(5))
            let discoveredModels = output.map(parser.codexModels(from:)) ?? []
            if !discoveredModels.isEmpty {
                return discovered(
                    discoveredModels,
                    defaultModel: await codexDefaultModel(in: discoveredModels, home: codexHome)
                )
            }
            let url = codexHome.appendingPathComponent("models_cache.json")
            let models = await fileReader(url)
                .map(parser.codexModels(from:)) ?? []
            let defaultModel = await codexDefaultModel(in: models, home: codexHome)
            guard !models.isEmpty else {
                return await failedDiscovery(
                    for: provider,
                    commandReturnedOutput: output != nil,
                    executable: executable
                )
            }
            return discovered(models, defaultModel: defaultModel)
        case .claude:
            let executable = Self.shellArgument(claudeExecutable)
            let output = await commandRunner(
                Self.claudeModelListCommand(executable: executable),
                .seconds(30)
            )
            let models = output.map(parser.claudeModels(from:)) ?? []
            let defaultModel = output.flatMap(parser.claudeDefaultModel(from:))
            guard !models.isEmpty || defaultModel != nil else {
                return await failedDiscovery(
                    for: provider,
                    commandReturnedOutput: output != nil,
                    executable: executable
                )
            }
            return discovered(models, defaultModel: defaultModel)
        }
    }

    private func failedDiscovery(
        for provider: MobileTaskModelProvider,
        commandReturnedOutput: Bool,
        executable: String? = nil
    ) async -> MobileTaskModelListResult {
        let error: MobileTaskModelListError
        if commandReturnedOutput {
            error = .queryFailed
        } else {
            let availability = await commandRunner(
                "command -v \(executable ?? provider.rawValue)",
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
        in models: [MobileTaskModel], home: URL
    ) async -> MobileTaskModel? {
        guard !models.isEmpty else { return nil }
        let url = home.appendingPathComponent("config.toml")
        guard let data = await fileReader(url),
              let configuredID = parser.codexConfiguredModel(from: data) else {
            return nil
        }
        return models.first { $0.id == configuredID }
    }

    private static func shellArgument(_ value: String) -> String {
        // fish also interprets backslashes before quotes inside single quotes.
        value.components(separatedBy: "\\")
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: "\\\\")
    }

    private static func claudeModelListCommand(executable: String) -> String {
        #"""
        set -o pipefail
        /usr/bin/printf '%s\n' '{"type":"control_request","request_id":"cmux-list-options","request":{"subtype":"list_models"}}' | CLAUDE_CODE_ENTRYPOINT=cmux-task-models \#(executable) -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose
        """#
    }
}
