import Foundation

/// Describes the PTY transfer into the root-staged, signature-verified bundled executor.
struct SudoReviewedScriptTransport: Sendable, Equatable {
    let reviewedScript: Data
    let approvedScriptURL: URL
    let privilegedHelper: SudoVerifiedHelper
    let staging: SudoHelperStagingCommand
    let deadline: Date
    let controlMarkers: SudoExecutionControlMarkers

    /// Arguments passed to the staged executor after the hidden command.
    var executorArguments: [String] {
        [
            SudoPrivilegedExecutor.hiddenCommand,
            String(reviewedScript.count),
            String(deadline.timeIntervalSince1970),
            approvedScriptURL.standardizedFileURL.path,
            SudoSHA256.hex(reviewedScript),
            controlMarkers.token,
        ]
    }

    var shellArguments: [String] {
        staging.arguments(
            helper: privilegedHelper,
            failureMarker: controlMarkers.transportFailed,
            helperArguments: executorArguments
        )
    }
}
