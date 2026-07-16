import Foundation

/// Immutable output from one Git subprocess.
struct WorkspaceChangesGitResult: Sendable, Equatable {
    let output: Data
    let exitCode: Int32
}
