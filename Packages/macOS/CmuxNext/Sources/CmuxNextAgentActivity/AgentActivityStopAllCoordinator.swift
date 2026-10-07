import Foundation

/// Fans out Stop All to the CUA, browser, and ACP control sources.
@MainActor
public final class AgentActivityStopAllCoordinator {
    private let sources: [any AgentActivitySource]

    /// Creates a coordinator from all control sources visible to the pane.
    public init(sources: [any AgentActivitySource]) {
        self.sources = sources
    }

    /// Sends the stop request to every source and reports the first failure.
    public func stopAll(machine: String) async throws {
        var firstError: Error?
        for source in sources {
            do {
                try await source.perform(.stopAll(machine: machine))
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }
}
