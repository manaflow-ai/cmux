public import Foundation
@preconcurrency import Sparkle

private let sparkleResumeAppcastErrorCode = 1004
private let sparkleTemporaryDirectoryErrorCode = 2000
private let sparkleDownloadErrorCode = 2001
private let sparkleUnarchivingErrorCode = 3000
private let sparkleFileCopyFailureErrorCode = 4000
private let sparkleAuthenticationFailureErrorCode = 4001
private let sparkleMissingUpdateErrorCode = 4002
private let sparkleMissingInstallerToolErrorCode = 4003
private let sparkleRelaunchErrorCode = 4004
private let sparkleInstallationErrorCode = 4005
private let sparkleAgentInvalidationErrorCode = 4010
private let sparkleInstallationWriteNoPermissionErrorCode = 4012

/// Chooses a direct-download recovery URL for update failures where the in-app install path is
/// broken but fetching the active channel manually is still safe.
public struct UpdateManualDownloadRecovery: Sendable {
    private let stableDownloadURLString: String
    private let nightlyDownloadURLString: String

    /// Creates a recovery resolver.
    ///
    /// - Parameters:
    ///   - stableDownloadURLString: Direct DMG URL for the stable channel.
    ///   - nightlyDownloadURLString: Direct DMG URL for the nightly channel.
    public init(
        stableDownloadURLString: String = "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg",
        nightlyDownloadURLString: String = "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg"
    ) {
        self.stableDownloadURLString = stableDownloadURLString
        self.nightlyDownloadURLString = nightlyDownloadURLString
    }

    /// Returns a direct download URL when manually downloading is a sensible recovery for
    /// `error`, or `nil` when it is not.
    ///
    /// Returned for installation, extraction, resume, and download failures, including cmux's
    /// own install-watchdog trip, where grabbing the latest build sidesteps a broken in-app
    /// install. Returns `nil` for feed, signature, configuration, and "already up to date" errors,
    /// where a manual download would not help or could be unsafe.
    ///
    /// - Parameter feedURLString: The feed URL in effect at failure time, used to route recovery
    ///   to the failing build's own channel. A NIGHTLY build must be pointed at nightly recovery,
    ///   not the latest stable DMG.
    public func url(for error: any Swift.Error, feedURLString: String? = nil) -> URL? {
        let nsError = error as NSError
        if nsError.domain == UpdateStateModel.updateErrorDomain,
           nsError.code == UpdateStateModel.installDidNotStartCode {
            return channelURL(feedURLString: feedURLString)
        }
        guard nsError.domain == SUSparkleErrorDomain else { return nil }
        switch nsError.code {
        case sparkleResumeAppcastErrorCode,
             sparkleTemporaryDirectoryErrorCode,
             sparkleDownloadErrorCode,
             sparkleUnarchivingErrorCode,
             sparkleFileCopyFailureErrorCode,
             sparkleAuthenticationFailureErrorCode,
             sparkleMissingUpdateErrorCode,
             sparkleMissingInstallerToolErrorCode,
             sparkleRelaunchErrorCode,
             sparkleInstallationErrorCode,
             sparkleAgentInvalidationErrorCode,
             sparkleInstallationWriteNoPermissionErrorCode:
            return channelURL(feedURLString: feedURLString)
        default:
            return nil
        }
    }

    private func channelURL(feedURLString: String?) -> URL? {
        if let feedURLString, feedURLString.contains("/nightly/") {
            return URL(string: nightlyDownloadURLString)
        }
        return URL(string: stableDownloadURLString)
    }
}
