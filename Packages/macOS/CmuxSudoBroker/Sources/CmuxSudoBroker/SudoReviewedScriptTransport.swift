import Foundation

/// Describes the PTY transfer into the root-owned bundled executor.
struct SudoReviewedScriptTransport: Sendable, Equatable {
    let reviewedScript: Data
    let approvedScriptURL: URL
    let privilegedHelperExecutableURL: URL
    let deadline: Date
    let controlToken: String

    var shellArguments: [String] {
        [
            privilegedHelperExecutableURL.standardizedFileURL.path,
            SudoPrivilegedExecutor.hiddenCommand,
            String(reviewedScript.count),
            String(deadline.timeIntervalSince1970),
            approvedScriptURL.standardizedFileURL.path,
            controlToken,
        ]
    }
}
