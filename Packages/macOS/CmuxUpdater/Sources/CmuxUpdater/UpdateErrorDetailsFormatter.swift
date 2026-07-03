public import Foundation
@preconcurrency import Sparkle

/// Builds the copyable technical detail block shown in the update error popover.
public struct UpdateErrorDetailsFormatter: Sendable {
    /// Creates an error-details formatter.
    public init() {}

    /// Builds a multi-line technical detail block.
    ///
    /// - Parameters:
    ///   - error: The error to describe.
    ///   - technicalDetails: Extra detail captured at failure time, if any.
    ///   - feedURLString: The feed URL in effect at failure time, if any.
    ///   - logPath: The path of the update log file, appended so users can find the full trace.
    /// - Returns: A newline-separated detail block.
    public func details(for error: any Swift.Error,
                        technicalDetails: String?,
                        feedURLString: String?,
                        logPath: String) -> String {
        let nsError = error as NSError
        var lines: [String] = []
        lines.append("Message: \(nsError.localizedDescription)")
        lines.append("Domain: \(nsError.domain)")
        if nsError.domain == SUSparkleErrorDomain,
           let sparkleName = sparkleErrorCodeName(for: nsError.code) {
            lines.append("Code: \(sparkleName) (\(nsError.code))")
        } else {
            lines.append("Code: \(nsError.code)")
        }

        if let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            lines.append("URL: \(url.absoluteString)")
        } else if let urlString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            lines.append("URL: \(urlString)")
        }

        if let failure = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String,
           !failure.isEmpty {
            lines.append("Failure: \(failure)")
        }
        if let recovery = nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String,
           !recovery.isEmpty {
            lines.append("Recovery: \(recovery)")
        }

        if let feedURLString, !feedURLString.isEmpty {
            lines.append("Feed: \(feedURLString)")
        }

        if let technicalDetails, !technicalDetails.isEmpty {
            lines.append("Debug: \(technicalDetails)")
        }

        lines.append("Log: \(logPath)")
        return lines.joined(separator: "\n")
    }

    private func sparkleErrorCodeName(for code: Int) -> String? {
        switch code {
        case 1: return "SUNoPublicDSAFoundError"
        case 2: return "SUInsufficientSigningError"
        case 3: return "SUInsecureFeedURLError"
        case 4: return "SUInvalidFeedURLError"
        case 5: return "SUInvalidUpdaterError"
        case 6: return "SUInvalidHostBundleIdentifierError"
        case 7: return "SUInvalidHostVersionError"
        case 1000: return "SUAppcastParseError"
        case 1001: return "SUNoUpdateError"
        case 1002: return "SUAppcastError"
        case 1003: return "SURunningFromDiskImageError"
        case 1004: return "SUResumeAppcastError"
        case 1005: return "SURunningTranslocated"
        case 1006: return "SUWebKitTerminationError"
        case 1007: return "SUReleaseNotesError"
        case 2000: return "SUTemporaryDirectoryError"
        case 2001: return "SUDownloadError"
        case 3000: return "SUUnarchivingError"
        case 3001: return "SUSignatureError"
        case 3002: return "SUValidationError"
        case 4000: return "SUFileCopyFailure"
        case 4001: return "SUAuthenticationFailure"
        case 4002: return "SUMissingUpdateError"
        case 4003: return "SUMissingInstallerToolError"
        case 4004: return "SURelaunchError"
        case 4005: return "SUInstallationError"
        case 4006: return "SUDowngradeError"
        case 4007: return "SUInstallationCanceledError"
        case 4008: return "SUInstallationAuthorizeLaterError"
        case 4009: return "SUNotValidUpdateError"
        case 4010: return "SUAgentInvalidationError"
        case 4012: return "SUInstallationWriteNoPermissionError"
        case 5000: return "SUIncorrectAPIUsageError"
        default:
            return nil
        }
    }
}
