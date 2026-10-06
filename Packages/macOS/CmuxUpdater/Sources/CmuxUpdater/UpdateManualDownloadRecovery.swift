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
    private static let defaultDevDownloadURLString = "https://files.cmux.com/cmux-dev/classic/latest.zip"
    private let stableDownloadURLString: String
    private let nightlyDownloadURLString: String
    private let rcDownloadURLString: String
    private let devDownloadURLString: String

    /// Creates a recovery resolver.
    ///
    /// - Parameters:
    ///   - stableDownloadURLString: Direct DMG URL for the stable channel.
    ///   - nightlyDownloadURLString: Direct DMG URL for the nightly channel. Defaults to the
    ///     nightly DMG for `hostArchitecture`, since nightly ships one DMG per architecture.
    ///   - rcDownloadURLString: Direct DMG URL for the RC channel. Defaults to the RC DMG for
    ///     `hostArchitecture`, since RC ships one DMG per architecture like nightly.
    ///   - devDownloadURLString: Direct ZIP URL for the team dev channel.
    ///   - hostArchitecture: The architecture whose nightly and RC DMGs are offered by default.
    public init(
        stableDownloadURLString: String = "https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg",
        nightlyDownloadURLString: String? = nil,
        rcDownloadURLString: String? = nil,
        devDownloadURLString: String = "https://files.cmux.com/cmux-dev/classic/latest.zip",
        hostArchitecture: UpdateHostArchitecture = .current
    ) {
        self.stableDownloadURLString = stableDownloadURLString
        self.nightlyDownloadURLString = nightlyDownloadURLString
            ?? Self.nightlyDownloadURLString(for: hostArchitecture)
        self.rcDownloadURLString = rcDownloadURLString
            ?? Self.rcDownloadURLString(for: hostArchitecture)
        self.devDownloadURLString = devDownloadURLString
    }

    /// The direct nightly DMG URL for `architecture`.
    public static func nightlyDownloadURLString(for architecture: UpdateHostArchitecture) -> String {
        "https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos-\(architecture.rawValue).dmg"
    }

    /// The direct RC DMG URL for `architecture`.
    public static func rcDownloadURLString(for architecture: UpdateHostArchitecture) -> String {
        "https://github.com/manaflow-ai/cmux/releases/download/rc/cmux-rc-macos-\(architecture.rawValue).dmg"
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
    ///   to the failing build's own channel. A NIGHTLY or RC build must be pointed at its own
    ///   channel's recovery DMG, not the latest stable DMG.
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
        switch UpdateFeedResolver.Channel.classify(feedURL: feedURLString ?? "") {
        case .nightly:
            return URL(string: nightlyDownloadURLString)
        case .rc:
            return URL(string: rcDownloadURLString)
        case .dev:
            return URL(string: devDownloadURL(for: feedURLString))
        case .stable:
            return URL(string: stableDownloadURLString)
        }
    }

    private func devDownloadURL(for feedURLString: String?) -> String {
        guard devDownloadURLString == Self.defaultDevDownloadURLString else {
            return devDownloadURLString
        }
        guard let feedURLString,
              let components = URLComponents(string: feedURLString),
              let track = Self.devTrack(in: components.path)
        else {
            return devDownloadURLString
        }
        guard var download = URLComponents(string: devDownloadURLString) else {
            return devDownloadURLString
        }
        var path = download.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let devIndex = path.firstIndex(of: "cmux-dev") else {
            return devDownloadURLString
        }
        if path.count > devIndex + 1 {
            path[devIndex + 1] = track
        } else {
            path.append(track)
        }
        if path.last != "latest.zip" {
            path.append("latest.zip")
        }
        download.path = "/" + path.joined(separator: "/")
        return download.string ?? devDownloadURLString
    }

    private static func devTrack(in path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let index = components.firstIndex(of: "cmux-dev"), components.count > index + 1 else {
            return nil
        }
        let track = components[index + 1]
        return track == "classic" || track == "next" ? track : nil
    }
}
