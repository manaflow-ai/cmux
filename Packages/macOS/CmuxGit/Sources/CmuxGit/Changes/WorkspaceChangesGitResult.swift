import Foundation

/// Immutable output from one Git subprocess.
struct WorkspaceChangesGitResult: Sendable, Equatable {
    let output: Data
    let exitCode: Int32
    let standardOutputWasTruncated: Bool

    init(
        output: Data,
        exitCode: Int32,
        standardOutputWasTruncated: Bool = false
    ) {
        self.output = output
        self.exitCode = exitCode
        self.standardOutputWasTruncated = standardOutputWasTruncated
    }
}
