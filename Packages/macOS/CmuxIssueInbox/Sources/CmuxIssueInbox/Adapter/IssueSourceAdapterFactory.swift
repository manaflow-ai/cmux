public import CmuxFoundation
public import Foundation

/// Builds concrete adapters from Issue Inbox source configuration.
public struct IssueSourceAdapterFactory: Sendable {
    private let transport: any IssueInboxHTTPTransport
    private let commandRunner: any CommandRunning
    private let environment: [String: String]
    private let currentDirectory: String

    /// Creates an adapter factory.
    ///
    /// - Parameters:
    ///   - transport: HTTP transport used by provider adapters.
    ///   - commandRunner: Runner used by GitHub `gh auth token` fallback.
    ///   - environment: Process environment used by provider auth.
    ///   - currentDirectory: Working directory for subprocess auth probes.
    public init(
        transport: any IssueInboxHTTPTransport = URLSessionIssueInboxHTTPTransport(),
        commandRunner: any CommandRunning = CommandRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.transport = transport
        self.commandRunner = commandRunner
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    /// Builds adapters for every valid source config.
    ///
    /// - Parameter configs: Source configurations.
    /// - Returns: Adapters, in config order.
    /// - Throws: Adapter construction errors.
    public func adapters(for configs: [IssueInboxSourceConfig]) throws -> [any IssueSourceAdapter] {
        try configs.map { config in
            switch config.type {
            case .github:
                return try GitHubIssueSourceAdapter(
                    config: config,
                    transport: transport,
                    commandRunner: commandRunner,
                    environment: environment,
                    currentDirectory: currentDirectory
                )
            case .linear:
                return try LinearIssueSourceAdapter(
                    config: config,
                    transport: transport,
                    environment: environment
                )
            }
        }
    }
}
