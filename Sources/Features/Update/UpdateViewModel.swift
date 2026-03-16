import AppKit
import Foundation
import Sparkle
import SwiftUI

// MARK: - UpdateViewModel

final class UpdateViewModel: ObservableObject {
    // MARK: Properties

    @Published var state: UpdateState = .idle
    @Published var overrideState: UpdateState?
    #if DEBUG
        @Published var debugOverrideText: String?
    #endif

    // MARK: Computed Properties

    var effectiveState: UpdateState {
        overrideState ?? state
    }

    var text: String {
        #if DEBUG
            if let debugOverrideText { return debugOverrideText }
        #endif
        switch effectiveState {
            case .idle:
                return ""

            case .permissionRequest:
                return String(localized: "update.permissionRequest.text", defaultValue: "Enable Automatic Updates?")

            case .checking:
                return String(localized: "update.checking", defaultValue: "Checking for Updates…")

            case let .updateAvailable(update):
                let version = update.appcastItem.displayVersionString
                if !version.isEmpty {
                    return String(localized: "update.available.withVersion", defaultValue: "Update Available: \(version)")
                }
                return String(localized: "update.available.short", defaultValue: "Update Available")

            case let .downloading(download):
                if let expectedLength = download.expectedLength, expectedLength > 0 {
                    let progress = Double(download.progress) / Double(expectedLength)
                    let percent = String(format: "%.0f%%", progress * 100)
                    return String(localized: "update.downloading.progress", defaultValue: "Downloading: \(percent)")
                }
                return String(localized: "update.downloading.status", defaultValue: "Downloading…")

            case let .extracting(extracting):
                let percent = String(format: "%.0f%%", extracting.progress * 100)
                return String(localized: "update.extracting.progress", defaultValue: "Preparing: \(percent)")

            case let .installing(install):
                return install.isAutoUpdate ? String(localized: "update.restartToComplete", defaultValue: "Restart to Complete Update") : String(localized: "update.installing.status", defaultValue: "Installing…")

            case .notFound:
                return String(localized: "update.noUpdates.title", defaultValue: "No Updates Available")

            case let .error(err):
                return Self.userFacingErrorTitle(for: err.error)
        }
    }

    var maxWidthText: String {
        switch effectiveState {
            case .downloading:
                "Downloading: 100%"
            case .extracting:
                "Preparing: 100%"
            default:
                text
        }
    }

    var iconName: String? {
        switch effectiveState {
            case .idle:
                nil
            case .permissionRequest:
                "questionmark.circle"
            case .checking:
                "arrow.triangle.2.circlepath"
            case .updateAvailable:
                "shippingbox.fill"
            case .downloading:
                "arrow.down.circle"
            case .extracting:
                "shippingbox"
            case .installing:
                "power.circle"
            case .notFound:
                "info.circle"
            case .error:
                "exclamationmark.triangle.fill"
        }
    }

    var description: String {
        switch effectiveState {
            case .idle:
                ""
            case .permissionRequest:
                String(localized: "update.configureAutoUpdates", defaultValue: "Configure automatic update preferences")
            case .checking:
                String(localized: "update.pleaseWait", defaultValue: "Please wait while we check for available updates")
            case let .updateAvailable(update):
                update.releaseNotes?.label ?? String(localized: "update.downloadAndInstall", defaultValue: "Download and install the latest version")
            case .downloading:
                String(localized: "update.downloadingPackage", defaultValue: "Downloading the update package")
            case .extracting:
                String(localized: "update.preparingUpdate", defaultValue: "Extracting and preparing the update")
            case let .installing(install):
                install.isAutoUpdate ? String(localized: "update.restartToComplete", defaultValue: "Restart to Complete Update") : String(localized: "update.installingAndRestarting", defaultValue: "Installing update and preparing to restart")
            case .notFound:
                String(localized: "update.noUpdates.message", defaultValue: "You are running the latest version")
            case let .error(err):
                Self.userFacingErrorMessage(for: err.error)
        }
    }

    var badge: String? {
        switch effectiveState {
            case let .updateAvailable(update):
                let version = update.appcastItem.displayVersionString
                return version.isEmpty ? nil : version

            case let .downloading(download):
                if let expectedLength = download.expectedLength, expectedLength > 0 {
                    let percentage = Double(download.progress) / Double(expectedLength) * 100
                    return String(format: "%.0f%%", percentage)
                }
                return nil

            case let .extracting(extracting):
                return String(format: "%.0f%%", extracting.progress * 100)

            default:
                return nil
        }
    }

    var iconColor: Color {
        switch effectiveState {
            case .idle:
                .secondary
            case .permissionRequest:
                .white
            case .checking:
                .secondary
            case .updateAvailable:
                cmuxAccentColor()
            case .downloading, .extracting, .installing:
                .secondary
            case .notFound:
                .secondary
            case .error:
                .orange
        }
    }

    var backgroundColor: Color {
        switch effectiveState {
            case .permissionRequest:
                Color(nsColor: NSColor.systemBlue.blended(withFraction: 0.3, of: .black) ?? .systemBlue)
            case .updateAvailable:
                cmuxAccentColor()
            case .notFound:
                Color(nsColor: NSColor.systemBlue.blended(withFraction: 0.5, of: .black) ?? .systemBlue)
            case .error:
                .orange.opacity(0.2)
            default:
                Color(nsColor: .controlBackgroundColor)
        }
    }

    var foregroundColor: Color {
        switch effectiveState {
            case .permissionRequest:
                .white
            case .updateAvailable:
                .white
            case .notFound:
                .white
            case .error:
                .orange
            default:
                .primary
        }
    }

    // MARK: Static Functions

    static func userFacingErrorTitle(for error: Swift.Error) -> String {
        let nsError = error as NSError
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

    static func userFacingErrorMessage(for error: Swift.Error) -> String {
        let nsError = error as NSError
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
                case 1003, 1005, 4005:
                    return String(localized: "update.error.permissionError.message", defaultValue: "Move cmux into Applications and relaunch to enable updates.")
                default:
                    break
            }
        }
        return nsError.localizedDescription
    }

    static func errorDetails(for error: Swift.Error, technicalDetails: String?, feedURLString: String?) -> String {
        let nsError = error as NSError
        var lines: [String] = []
        lines.append("Message: \(nsError.localizedDescription)")
        lines.append("Domain: \(nsError.domain)")
        if nsError.domain == SUSparkleErrorDomain,
           let sparkleName = sparkleErrorCodeName(for: nsError.code)
        {
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
           !failure.isEmpty
        {
            lines.append("Failure: \(failure)")
        }
        if let recovery = nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String,
           !recovery.isEmpty
        {
            lines.append("Recovery: \(recovery)")
        }

        if let feedURLString, !feedURLString.isEmpty {
            lines.append("Feed: \(feedURLString)")
        }

        if let technicalDetails, !technicalDetails.isEmpty {
            lines.append("Debug: \(technicalDetails)")
        }

        lines.append("Log: \(UpdateLogStore.shared.logPath())")
        return lines.joined(separator: "\n")
    }

    private static func networkError(from error: NSError) -> NSError? {
        if error.domain == NSURLErrorDomain {
            return error
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain
        {
            return underlying
        }
        return nil
    }

    private static func sparkleErrorCodeName(for code: Int) -> String? {
        switch code {
            case 1: "SUNoPublicDSAFoundError"
            case 2: "SUInsufficientSigningError"
            case 3: "SUInsecureFeedURLError"
            case 4: "SUInvalidFeedURLError"
            case 1000: "SUAppcastParseError"
            case 1001: "SUNoUpdateError"
            case 1002: "SUAppcastError"
            case 1003: "SURunningFromDiskImageError"
            case 1005: "SURunningTranslocated"
            case 2001: "SUDownloadError"
            case 3001: "SUSignatureError"
            case 3002: "SUValidationError"
            default:
                nil
        }
    }
}

// MARK: - UpdateState

enum UpdateState: Equatable {
    case idle
    case permissionRequest(PermissionRequest)
    case checking(Checking)
    case updateAvailable(UpdateAvailable)
    case notFound(NotFound)
    case error(Error)
    case downloading(Downloading)
    case extracting(Extracting)
    case installing(Installing)

    // MARK: Nested Types

    struct NotFound {
        let acknowledgement: () -> Void
    }

    struct PermissionRequest {
        let request: SPUUpdatePermissionRequest
        let reply: @Sendable (SUUpdatePermissionResponse) -> Void
    }

    struct Checking {
        let cancel: () -> Void
    }

    struct UpdateAvailable {
        // MARK: Properties

        let appcastItem: SUAppcastItem
        let reply: @Sendable (SPUUserUpdateChoice) -> Void

        // MARK: Computed Properties

        var releaseNotes: ReleaseNotes? {
            ReleaseNotes(displayVersionString: appcastItem.displayVersionString)
        }
    }

    enum ReleaseNotes {
        case commit(URL)
        case tagged(URL)

        // MARK: Computed Properties

        var url: URL {
            switch self {
                case let .commit(url): url
                case let .tagged(url): url
            }
        }

        var label: String {
            switch self {
                case .commit: String(localized: "update.viewGitHubCommit", defaultValue: "View GitHub Commit")
                case .tagged: String(localized: "update.viewReleaseNotes", defaultValue: "View Release Notes")
            }
        }

        // MARK: Lifecycle

        init?(displayVersionString: String) {
            let version = displayVersionString

            if let semver = Self.extractSemanticVersion(from: version) {
                let tag = semver.hasPrefix("v") ? semver : "v\(semver)"
                if let url = URL(string: "https://github.com/manaflow-ai/cmux/releases/tag/\(tag)") {
                    self = .tagged(url)
                    return
                }
            }

            guard let newHash = Self.extractGitHash(from: version) else {
                return nil
            }

            if let url = URL(string: "https://github.com/manaflow-ai/cmux/commit/\(newHash)") {
                self = .commit(url)
            } else {
                return nil
            }
        }

        // MARK: Static Functions

        private static func extractSemanticVersion(from version: String) -> String? {
            let pattern = #"v?\d+\.\d+\.\d+"#
            if let range = version.range(of: pattern, options: .regularExpression) {
                return String(version[range])
            }
            return nil
        }

        private static func extractGitHash(from version: String) -> String? {
            let pattern = #"[0-9a-f]{7,40}"#
            if let range = version.range(of: pattern, options: .regularExpression) {
                return String(version[range])
            }
            return nil
        }
    }

    struct Error {
        // MARK: Properties

        let error: any Swift.Error
        let retry: () -> Void
        let dismiss: () -> Void
        let technicalDetails: String?
        let feedURLString: String?

        // MARK: Lifecycle

        init(error: any Swift.Error,
             retry: @escaping () -> Void,
             dismiss: @escaping () -> Void,
             technicalDetails: String? = nil,
             feedURLString: String? = nil)
        {
            self.error = error
            self.retry = retry
            self.dismiss = dismiss
            self.technicalDetails = technicalDetails
            self.feedURLString = feedURLString
        }
    }

    struct Downloading {
        let cancel: () -> Void
        let expectedLength: UInt64?
        let progress: UInt64
    }

    struct Extracting {
        let progress: Double
    }

    struct Installing {
        var isAutoUpdate = false
        let retryTerminatingApplication: () -> Void
        let dismiss: () -> Void
    }

    // MARK: Computed Properties

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isInstallable: Bool {
        switch self {
            case .checking,
                 .updateAvailable,
                 .downloading,
                 .extracting,
                 .installing:
                true
            default:
                false
        }
    }

    // MARK: Static Functions

    static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
            case (.idle, .idle):
                true
            case (.permissionRequest, .permissionRequest):
                true
            case (.checking, .checking):
                true
            case let (.updateAvailable(lUpdate), .updateAvailable(rUpdate)):
                lUpdate.appcastItem.displayVersionString == rUpdate.appcastItem.displayVersionString
            case (.notFound, .notFound):
                true
            case let (.error(lErr), .error(rErr)):
                lErr.error.localizedDescription == rErr.error.localizedDescription
            case let (.downloading(lDown), .downloading(rDown)):
                lDown.progress == rDown.progress && lDown.expectedLength == rDown.expectedLength
            case let (.extracting(lExt), .extracting(rExt)):
                lExt.progress == rExt.progress
            case let (.installing(lInstall), .installing(rInstall)):
                lInstall.isAutoUpdate == rInstall.isAutoUpdate
            default:
                false
        }
    }

    // MARK: Functions

    func cancel() {
        switch self {
            case let .checking(checking):
                checking.cancel()
            case let .updateAvailable(available):
                available.reply(.dismiss)
            case let .downloading(downloading):
                downloading.cancel()
            case let .notFound(notFound):
                notFound.acknowledgement()
            case let .error(err):
                err.dismiss()
            default:
                break
        }
    }

    func confirm() {
        switch self {
            case let .updateAvailable(available):
                available.reply(.install)
            default:
                break
        }
    }
}
