import Foundation

public nonisolated enum GitHubFeedError: Error, Sendable, Equatable {
    case cliUnavailable(String)
    case commandFailed(Int, Data)
}
