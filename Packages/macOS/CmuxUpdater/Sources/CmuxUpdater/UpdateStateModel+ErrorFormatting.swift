public import Foundation
@preconcurrency public import Sparkle

/// Error classification and presentation for the update flow.
///
/// These helpers turn a Sparkle (or `NSURLError`) failure into the short title, explanatory
/// message, optional manual-download recovery URL, and copyable technical detail block that
/// ``UpdateStateModel`` and the error popover render.
extension UpdateStateModel {
    nonisolated static let sparkleInvalidFeedURLCode = 4
    nonisolated static let sparkleInsecureFeedCode = 3
    nonisolated static let sparkleAppcastParseCode = 1000
    nonisolated static let sparkleAppcastCode = 1002
    nonisolated static let sparkleRunningFromDiskImageCode = 1003
    nonisolated static let sparkleRunningTranslocatedCode = 1005
    nonisolated static let sparkleResumeAppcastCode = 1004
    nonisolated static let sparkleTempDirectoryCode = 2000
    nonisolated static let sparkleDownloadCode = 2001
    nonisolated static let sparkleUnarchivingCode = 3000
    nonisolated static let sparkleInitialInstallationCode = 1
    nonisolated static let sparkleInitialInstallationNoUpdateCode = 2
    nonisolated static let sparkleSignatureCode = 3001
    nonisolated static let sparkleValidationCode = 3002
    nonisolated static let sparkleAuthenticationFailureCode = 4001
    nonisolated static let sparkleInstallationCode = 4005
    nonisolated static let sparkleAgentInvalidationCode = 4010
    nonisolated static let sparkleInstallationWriteNoPermissionCode = 4012
    nonisolated static let sparkleInternalAgentConnectionTimeoutCode = 10

    // MARK: - Error formatting

    /// A short, user-facing title for an update error.
    public static func userFacingErrorTitle(for error: any Swift.Error) -> String {
        let nsError = error as NSError
        if let networkError = updateNetworkError(from: nsError) {
            switch networkError.code {
            case NSURLErrorNotConnectedToInternet:
                return String(localized: "update.error.noInternet.title", defaultValue: "No Internet Connection")
            case NSURLErrorTimedOut:
                return String(localized: "update.error.timedOut.title", defaultValue: "Update Timed Out")
            case NSURLErrorCannotFindHost:
                return String(localized: "update.error.serverNotFound.title", defaultValue: "Server Not Found")
            case NSURLErrorCannotConnectToHost:
                return String(localized: "update.error.serverUnreachable.title", defaultValue: "Server Unreachable")
            case NSURLErrorNetworkConnectionLost:
                return String(localized: "update.error.connectionLost.title", defaultValue: "Connection Lost")
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid:
                return String(localized: "update.error.secureConnectionFailed.title", defaultValue: "Secure Connection Failed")
            default:
                break
            }
        }
        if isUpdaterAgentConnectionFailure(nsError) {
            return String(localized: "update.error.installerAgent.title", defaultValue: "Couldn’t Start Updater")
        }
        if nsError.domain == SUSparkleErrorDomain {
            switch nsError.code {
            case Self.sparkleInstallationCode:
                return String(localized: "update.error.permissionError.title", defaultValue: "Updater Permission Error")
            case Self.sparkleDownloadCode:
                return String(localized: "update.error.downloadFailed.title", defaultValue: "Couldn't Download Update")
            case Self.sparkleAppcastParseCode, Self.sparkleAppcastCode:
                return String(localized: "update.error.feedError.title", defaultValue: "Update Feed Error")
            case Self.sparkleInvalidFeedURLCode:
                return String(localized: "update.error.invalidFeed.title", defaultValue: "Invalid Update Feed")
            case Self.sparkleInsecureFeedCode:
                return String(localized: "update.error.insecureFeed.title", defaultValue: "Insecure Update Feed")
            case Self.sparkleInitialInstallationCode, Self.sparkleInitialInstallationNoUpdateCode, Self.sparkleSignatureCode, Self.sparkleValidationCode:
                return String(localized: "update.error.signatureError.title", defaultValue: "Update Signature Error")
            case Self.sparkleRunningFromDiskImageCode, Self.sparkleRunningTranslocatedCode:
                return String(localized: "update.error.appLocation.title", defaultValue: "App Location Issue")
            default:
                break
            }
        }
        return String(localized: "update.error.failed.title", defaultValue: "Update Failed")
    }

    /// A user-facing explanatory message for an update error.
    public static func userFacingErrorMessage(for error: any Swift.Error) -> String {
        let nsError = error as NSError
        if let networkError = updateNetworkError(from: nsError) {
            switch networkError.code {
            case NSURLErrorNotConnectedToInternet:
                return String(localized: "update.error.noInternet.message", defaultValue: "cmux can’t reach the update server. Check your internet connection and try again.")
            case NSURLErrorTimedOut:
                return String(localized: "update.error.timedOut.message", defaultValue: "The update server took too long to respond. Try again in a moment.")
            case NSURLErrorCannotFindHost:
                return String(localized: "update.error.serverNotFound.message", defaultValue: "The update server can’t be found. Check your connection or try again later.")
            case NSURLErrorCannotConnectToHost:
                return String(localized: "update.error.serverUnreachable.message", defaultValue: "cmux couldn’t connect to the update server. Check your connection or try again later.")
            case NSURLErrorNetworkConnectionLost:
                return String(localized: "update.error.connectionLost.message", defaultValue: "The network connection was lost while checking for updates. Try again.")
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid:
                return String(localized: "update.error.secureConnectionFailed.message", defaultValue: "A secure connection to the update server couldn’t be established. Try again later.")
            default:
                break
            }
        }
        if nsError.domain == SUSparkleErrorDomain {
            switch nsError.code {
            case Self.sparkleDownloadCode:
                return String(localized: "update.error.feedDownload.message", defaultValue: "cmux couldn't download the update feed. Check your connection and try again.")
            case Self.sparkleAppcastParseCode, Self.sparkleAppcastCode:
                return String(localized: "update.error.feedRead.message", defaultValue: "The update feed could not be read. Please try again later.")
            case Self.sparkleInvalidFeedURLCode:
                return String(localized: "update.error.invalidFeed.message", defaultValue: "The update feed URL is invalid. Please contact support.")
            case Self.sparkleInsecureFeedCode:
                return String(localized: "update.error.insecureFeed.message", defaultValue: "The update feed is insecure. Please contact support.")
            case Self.sparkleInitialInstallationCode, Self.sparkleInitialInstallationNoUpdateCode, Self.sparkleSignatureCode, Self.sparkleValidationCode:
                return String(localized: "update.error.signatureError.message", defaultValue: "The update's signature could not be verified. Please try again later.")
            case Self.sparkleRunningFromDiskImageCode, Self.sparkleRunningTranslocatedCode:
                return String(localized: "update.error.permissionError.message", defaultValue: "Move cmux into Applications and relaunch to enable updates.")
            case Self.sparkleInstallationCode, Self.sparkleAgentInvalidationCode:
                return String(localized: "update.error.installRecovery.message", defaultValue: "Move cmux into Applications and relaunch to enable updates. If it’s already in Applications, restart your Mac and try again, or download the latest version below.")
            default:
                break
            }
        }
        // Catch-all: keep user-facing copy in cmux terms; raw vendor descriptions, domains, and
        // codes stay in `errorDetails` (the copyable Details block + the update log), not here.
        return String(localized: "update.error.failed.message", defaultValue: "Something went wrong while checking for updates. Try again, or check the update log for details.")
    }

    /// A direct download URL for the latest release when manually downloading is a sensible
    /// recovery for `error`, or `nil` when it is not.
    ///
    /// Returned for installation, extraction, resume, and download failures, where grabbing the
    /// latest build sidesteps a broken in-app install (for example the wedged-launchd case this
    /// surfaces a "Download Latest Version" button for). Returns `nil` for feed, signature,
    /// configuration, and "already up to date" errors, where a manual download would not help or
    /// could be unsafe (notably signature/validation failures).
    public static func manualDownloadURL(for error: any Swift.Error) -> URL? {
        let nsError = error as NSError
        guard nsError.domain == SUSparkleErrorDomain else { return nil }
        switch nsError.code {
        case Self.sparkleResumeAppcastCode,
             Self.sparkleTempDirectoryCode,
             Self.sparkleDownloadCode,
             Self.sparkleUnarchivingCode,
             4000, Self.sparkleAuthenticationFailureCode, 4002, 4003, 4004, Self.sparkleInstallationCode, 4006,
             Self.sparkleAgentInvalidationCode,
             Self.sparkleInstallationWriteNoPermissionCode:
            return URL(string: manualDownloadURLString)
        default:
            return nil
        }
    }

    /// Builds the multi-line technical detail block shown in the error popover.
    ///
    /// - Parameters:
    ///   - error: The error to describe.
    ///   - technicalDetails: Extra detail captured at failure time, if any.
    ///   - feedURLString: The feed URL in effect at failure time, if any.
    ///   - logPath: The path of the update log file (from ``UpdateLogging/logPath()``), appended
    ///     so users can find the full trace.
    /// - Returns: A newline-separated detail block.
    public static func errorDetails(for error: any Swift.Error,
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

    /// The canonical direct-download URL for the latest stable release artifact, used as the
    /// manual fallback when Sparkle's in-app install path fails.
    private static let manualDownloadURLString = "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg"

}

/// Whether an update error is a transient network failure worth silently retrying
/// (offline, timeout, dropped connection, or a download/feed fetch that failed mid-flight —
/// GitHub's release CDN intermittently 504s individual objects, #5632). Signature,
/// configuration, and installer failures are not transient and must surface instead.
public func isTransientUpdateNetworkError(_ error: any Swift.Error) -> Bool {
    let nsError = error as NSError
    if let networkError = updateNetworkError(from: nsError) {
        switch networkError.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorResourceUnavailable,
             NSURLErrorBadServerResponse:
            return true
        default:
            break
        }
    }
    guard nsError.domain == SUSparkleErrorDomain else { return false }
    switch nsError.code {
    case UpdateStateModel.sparkleAppcastCode,
         UpdateStateModel.sparkleResumeAppcastCode,
         UpdateStateModel.sparkleDownloadCode:
        return true
    default:
        return false
    }
}

private func updateNetworkError(from error: NSError) -> NSError? {
    if error.domain == NSURLErrorDomain {
        return error
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
       underlying.domain == NSURLErrorDomain {
        return underlying
    }
    return nil
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

/// Whether an error reflects Sparkle's updater helper agent never connecting.
///
/// The login session's launchd domain can wedge into on-demand-only mode after a very long
/// uptime, so launchd refuses to spawn Sparkle's installer/progress agent and the install
/// times out ("agent connection was never initiated"). This surfaces as
/// ``SUAgentInvalidationError`` (4010), or as ``SUInstallationError`` (4005) wrapping Sparkle's
/// internal IPC-timeout error (code 10) or carrying the agent-connection text in its trace.
/// Restarting the Mac recreates the session domain and clears the wedge, so the user-facing
/// copy points there rather than at the misleading "move into Applications" guidance.
///
/// The match is deliberately narrow: a 4005 wrapping a different installer cause (e.g.
/// ``SUAuthenticationFailure`` 4001 or ``SURelaunchError`` 4004) is not a restart-fixable
/// agent failure, so it falls through to the generic "couldn't install" path.
private func isUpdaterAgentConnectionFailure(_ error: NSError) -> Bool {
    guard error.domain == SUSparkleErrorDomain else { return false }
    if error.code == UpdateStateModel.sparkleAgentInvalidationCode { return true }
    guard error.code == UpdateStateModel.sparkleInstallationCode else { return false }
    let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
    // Sparkle's internal "agent connection was never initiated" timeout is code 10 in its own
    // domain; that is the precise wedged-launchd signal.
    if let underlying,
       underlying.domain == SUSparkleErrorDomain,
       underlying.code == UpdateStateModel.sparkleInternalAgentConnectionTimeoutCode {
        return true
    }
    return mentionsAgentConnectionFailure(error)
        || (underlying.map(mentionsAgentConnectionFailure) ?? false)
}

/// Whether an error's user-facing text names the updater agent / remote-port connection drop.
private func mentionsAgentConnectionFailure(_ error: NSError) -> Bool {
    let text = [
        error.localizedDescription,
        (error.userInfo[NSLocalizedFailureReasonErrorKey] as? String) ?? "",
        (error.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String) ?? "",
    ].joined(separator: "\n").lowercased()
    return text.contains("agent connection") || text.contains("remote port")
}
