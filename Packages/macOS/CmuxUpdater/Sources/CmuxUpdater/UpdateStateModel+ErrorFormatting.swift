public import Foundation
@preconcurrency public import Sparkle

/// Error classification and presentation for the update flow.
///
/// These helpers turn a Sparkle (or `NSURLError`) failure into the short title, explanatory
/// message, optional manual-download recovery URL, and copyable technical detail block that
/// ``UpdateStateModel`` and the error popover render.
extension UpdateStateModel {
    // MARK: - Error formatting

    /// A short, user-facing title for an update error.
    public static func userFacingErrorTitle(for error: any Swift.Error) -> String {
        let nsError = error as NSError
        if nsError.domain == updateErrorDomain {
            switch nsError.code {
            case installDidNotStartCode:
                return String(localized: "update.error.didNotStart.title", defaultValue: "Update Didn’t Start")
            case updaterNotReadyCode:
                return String(localized: "update.error.updaterNotReady.title", defaultValue: "Updater Not Ready")
            default:
                // An unrecognized cmux.update code falls through to the generic title below
                // rather than masquerading as a known failure.
                break
            }
        }
        if let networkError = networkError(from: nsError) {
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
            case 4005:
                return String(localized: "update.error.permissionError.title", defaultValue: "Updater Permission Error")
            case 2001:
                return String(localized: "update.error.downloadFailed.title", defaultValue: "Couldn't Download Update")
            case 1000, 1002:
                return String(localized: "update.error.feedError.title", defaultValue: "Update Feed Error")
            case 4:
                return String(localized: "update.error.invalidFeed.title", defaultValue: "Invalid Update Feed")
            case 3:
                return String(localized: "update.error.insecureFeed.title", defaultValue: "Insecure Update Feed")
            case 1, 2, 3001, 3002:
                return String(localized: "update.error.signatureError.title", defaultValue: "Update Signature Error")
            case 1003, 1005:
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
        if nsError.domain == updateErrorDomain {
            // cmux-originated errors already carry user-ready, localized copy.
            let description = nsError.localizedDescription
            if !description.isEmpty {
                return description
            }
        }
        if let networkError = networkError(from: nsError) {
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
            case 2001:
                return String(localized: "update.error.feedDownload.message", defaultValue: "cmux couldn't download the update feed. Check your connection and try again.")
            case 1000, 1002:
                return String(localized: "update.error.feedRead.message", defaultValue: "The update feed could not be read. Please try again later.")
            case 4:
                return String(localized: "update.error.invalidFeed.message", defaultValue: "The update feed URL is invalid. Please contact support.")
            case 3:
                return String(localized: "update.error.insecureFeed.message", defaultValue: "The update feed is insecure. Please contact support.")
            case 1, 2, 3001, 3002:
                return String(localized: "update.error.signatureError.message", defaultValue: "The update's signature could not be verified. Please try again later.")
            case 1003, 1005:
                return String(localized: "update.error.permissionError.message", defaultValue: "Move cmux into Applications and relaunch to enable updates.")
            case 4005, 4010:
                return String(localized: "update.error.installRecovery.message", defaultValue: "Move cmux into Applications and relaunch to enable updates. If it’s already in Applications, restart your Mac and try again, or download the latest version below.")
            default:
                break
            }
        }
        // Catch-all: keep user-facing copy in cmux terms; raw vendor descriptions, domains, and
        // codes stay in `errorDetails` (the copyable Details block + the update log), not here.
        return String(localized: "update.error.failed.message", defaultValue: "Something went wrong while checking for updates. Try again, or check the update log for details.")
    }

}

/// Whether an error reflects Sparkle's updater helper agent never connecting.
///
/// The login session's launchd domain can wedge into on-demand-only mode after a very long
/// uptime, so launchd refuses to spawn Sparkle's installer/progress agent and the install times
/// out ("agent connection was never initiated"). This surfaces as ``SUAgentInvalidationError``
/// (4010), or as ``SUInstallationError`` (4005) wrapping Sparkle's internal IPC-timeout error
/// (code 10) or carrying the agent-connection text in its trace.
private func isUpdaterAgentConnectionFailure(_ error: NSError) -> Bool {
    guard error.domain == SUSparkleErrorDomain else { return false }
    if error.code == 4010 { return true }
    guard error.code == 4005 else { return false }
    let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
    // Sparkle's internal "agent connection was never initiated" timeout is code 10 in its own
    // domain; that is the precise wedged-launchd signal.
    if let underlying, underlying.domain == SUSparkleErrorDomain, underlying.code == 10 {
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

private func networkError(from error: NSError) -> NSError? {
    if error.domain == NSURLErrorDomain {
        return error
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
       underlying.domain == NSURLErrorDomain {
        return underlying
    }
    return nil
}
