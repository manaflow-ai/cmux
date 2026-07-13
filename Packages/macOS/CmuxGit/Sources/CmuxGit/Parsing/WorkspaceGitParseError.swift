import Foundation

/// A malformed NUL-delimited Git plumbing response.
enum WorkspaceGitParseError: Error, Equatable, Sendable {
    case malformedPorcelain
    case malformedNumstat
}
