import Foundation
import AppKit
import SwiftUI
import Sparkle

class UpdateViewModel: ObservableObject {
    @Published var state: UpdateState = .idle
    @Published var overrideState: UpdateState?

    var effectiveState: UpdateState {
        overrideState ?? state
    }

    var text: String {
        switch effectiveState {
        case .idle:
            return ""
        case .permissionRequest:
            return "Enable Automatic Updates?"
        case .checking:
            return "Checking for Updates…"
        case .updateAvailable(let update):
            let version = update.appcastItem.displayVersionString
            if !version.isEmpty {
                return "Update Available: \(version)"
            }
            return "Update Available"
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                let progress = Double(download.progress) / Double(expectedLength)
                return String(format: "Downloading: %.0f%%", progress * 100)
            }
            return "Downloading…"
        case .extracting(let extracting):
            return String(format: "Preparing: %.0f%%", extracting.progress * 100)
        case .installing(let install):
            return install.isAutoUpdate ? "Restart to Complete Update" : "Installing…"
        case .notFound:
            return "No Updates Available"
        case .error(let err):
            return Self.userFacingErrorTitle(for: err.error)
        }
    }

    var maxWidthText: String {
        switch effectiveState {
        case .downloading:
            return "Downloading: 100%"
        case .extracting:
            return "Preparing: 100%"
        default:
            return text
        }
    }

    var iconName: String? {
        switch effectiveState {
        case .idle:
            return nil
        case .permissionRequest:
            return "questionmark.circle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .updateAvailable:
            return "shippingbox.fill"
        case .downloading:
            return "arrow.down.circle"
        case .extracting:
            return "shippingbox"
        case .installing:
            return "power.circle"
        case .notFound:
            return "info.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var description: String {
        switch effectiveState {
        case .idle:
            return ""
        case .permissionRequest:
            return "Configure automatic update preferences"
        case .checking:
            return "Please wait while we check for available updates"
        case .updateAvailable(let update):
            return update.releaseNotes?.label ?? "Download and install the latest version"
        case .downloading:
            return "Downloading the update package"
        case .extracting:
            return "Extracting and preparing the update"
        case let .installing(install):
            return install.isAutoUpdate ? "Restart to Complete Update" : "Installing update and preparing to restart"
        case .notFound:
            return "You are running the latest version"
        case .error(let err):
            return Self.userFacingErrorMessage(for: err.error)
        }
    }

    var badge: String? {
        switch effectiveState {
        case .updateAvailable(let update):
            let version = update.appcastItem.displayVersionString
            return version.isEmpty ? nil : version
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                let percentage = Double(download.progress) / Double(expectedLength) * 100
                return String(format: "%.0f%%", percentage)
            }
            return nil
        case .extracting(let extracting):
            return String(format: "%.0f%%", extracting.progress * 100)
        default:
            return nil
        }
    }

    var iconColor: Color {
        switch effectiveState {
        case .idle:
            return .secondary
        case .permissionRequest:
            return .white
        case .checking:
            return .secondary
        case .updateAvailable:
            return .accentColor
        case .downloading, .extracting, .installing:
            return .secondary
        case .notFound:
            return .secondary
        case .error:
            return .orange
        }
    }

    var backgroundColor: Color {
        switch effectiveState {
        case .permissionRequest:
            return Color(nsColor: NSColor.systemBlue.blended(withFraction: 0.3, of: .black) ?? .systemBlue)
        case .updateAvailable:
            return .accentColor
        case .notFound:
            return Color(nsColor: NSColor.systemBlue.blended(withFraction: 0.5, of: .black) ?? .systemBlue)
        case .error:
            return .orange.opacity(0.2)
        default:
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    var foregroundColor: Color {
        switch effectiveState {
        case .permissionRequest:
            return .white
        case .updateAvailable:
            return .white
        case .notFound:
            return .white
        case .error:
            return .orange
        default:
            return .primary
        }
    }

    static func userFacingErrorTitle(for error: Swift.Error) -> String {
        let nsError = error as NSError
        if let networkError = networkError(from: nsError) {
            switch networkError.code {
            case NSURLErrorNotConnectedToInternet:
                return "No Internet Connection"
            case NSURLErrorTimedOut:
                return "Update Timed Out"
            case NSURLErrorCannotFindHost:
                return "Server Not Found"
            case NSURLErrorCannotConnectToHost:
                return "Server Unreachable"
            case NSURLErrorNetworkConnectionLost:
                return "Connection Lost"
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid:
                return "Secure Connection Failed"
            default:
                break
            }
        }
        if nsError.domain == SUSparkleErrorDomain {
            switch nsError.code {
            case 4005:
                return "Updater Permission Error"
            case 2001:
                return "Couldn't Download Update"
            case 1000, 1002:
                return "Update Feed Error"
            case 4:
                return "Invalid Update Feed"
            case 3:
                return "Insecure Update Feed"
            case 1, 2, 3001, 3002:
                return "Update Signature Error"
            case 1003, 1005:
                return "App Location Issue"
            default:
                break
            }
        }
        return "Update Failed"
    }

    static func userFacingErrorMessage(for error: Swift.Error) -> String {
        let nsError = error as NSError
        if let networkError = networkError(from: nsError) {
            switch networkError.code {
            case NSURLErrorNotConnectedToInternet:
                return "cmux can’t reach the update server. Check your internet connection and try again."
            case NSURLErrorTimedOut:
                return "The update server took too long to respond. Try again in a moment."
            case NSURLErrorCannotFindHost:
                return "The update server can’t be found. Check your connection or try again later."
            case NSURLErrorCannotConnectToHost:
                return "cmux couldn’t connect to the update server. Check your connection or try again later."
            case NSURLErrorNetworkConnectionLost:
                return "The network connection was lost while checking for updates. Try again."
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid:
                return "A secure connection to the update server couldn’t be established. Try again later."
            default:
                break
            }
        }
        if nsError.domain == SUSparkleErrorDomain {
            switch nsError.code {
            case 2001:
                return "cmux couldn't download the update feed. Check your connection and try again."
            case 1000, 1002:
                return "The update feed could not be read. Please try again later."
            case 4:
                return "The update feed URL is invalid. Please contact support."
            case 3:
                return "The update feed is insecure. Please contact support."
            case 1, 2, 3001, 3002:
                return "The update's signature could not be verified. Please try again later."
            case 1003, 1005, 4005:
                return "Move cmux into Applications and relaunch to enable updates."
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

        lines.append("Log: \(UpdateLogStore.shared.logPath())")
        return lines.joined(separator: "\n")
    }

    private static func networkError(from error: NSError) -> NSError? {
        if error.domain == NSURLErrorDomain {
            return error
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain {
            return underlying
        }
        return nil
    }

    private static func sparkleErrorCodeName(for code: Int) -> String? {
        switch code {
        case 1: return "SUNoPublicDSAFoundError"
        case 2: return "SUInsufficientSigningError"
        case 3: return "SUInsecureFeedURLError"
        case 4: return "SUInvalidFeedURLError"
        case 1000: return "SUAppcastParseError"
        case 1001: return "SUNoUpdateError"
        case 1002: return "SUAppcastError"
        case 1003: return "SURunningFromDiskImageError"
        case 1005: return "SURunningTranslocated"
        case 2001: return "SUDownloadError"
        case 3001: return "SUSignatureError"
        case 3002: return "SUValidationError"
        default:
            return nil
        }
    }
}

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
            return true
        default:
            return false
        }
    }

    func cancel() {
        switch self {
        case .checking(let checking):
            checking.cancel()
        case .updateAvailable(let available):
            available.reply(.dismiss)
        case .downloading(let downloading):
            downloading.cancel()
        case .notFound(let notFound):
            notFound.acknowledgement()
        case .error(let err):
            err.dismiss()
        default:
            break
        }
    }

    func confirm() {
        switch self {
        case .updateAvailable(let available):
            available.reply(.install)
        default:
            break
        }
    }

    static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.permissionRequest, .permissionRequest):
            return true
        case (.checking, .checking):
            return true
        case (.updateAvailable(let lUpdate), .updateAvailable(let rUpdate)):
            return lUpdate.appcastItem.displayVersionString == rUpdate.appcastItem.displayVersionString
        case (.notFound, .notFound):
            return true
        case (.error(let lErr), .error(let rErr)):
            return lErr.error.localizedDescription == rErr.error.localizedDescription
        case (.downloading(let lDown), .downloading(let rDown)):
            return lDown.progress == rDown.progress && lDown.expectedLength == rDown.expectedLength
        case (.extracting(let lExt), .extracting(let rExt)):
            return lExt.progress == rExt.progress
        case (.installing(let lInstall), .installing(let rInstall)):
            return lInstall.isAutoUpdate == rInstall.isAutoUpdate
        default:
            return false
        }
    }

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
        let appcastItem: SUAppcastItem
        let reply: @Sendable (SPUUserUpdateChoice) -> Void

        var releaseNotes: ReleaseNotes? {
            ReleaseNotes(displayVersionString: appcastItem.displayVersionString)
        }
    }

    enum ReleaseNotes {
        case commit(URL)
        case tagged(URL)

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

        var url: URL {
            switch self {
            case .commit(let url): return url
            case .tagged(let url): return url
            }
        }

        var label: String {
            switch self {
            case .commit: return "View GitHub Commit"
            case .tagged: return "View Release Notes"
            }
        }
    }

    struct Error {
        let error: any Swift.Error
        let retry: () -> Void
        let dismiss: () -> Void
        let technicalDetails: String?
        let feedURLString: String?

        init(error: any Swift.Error,
             retry: @escaping () -> Void,
             dismiss: @escaping () -> Void,
             technicalDetails: String? = nil,
             feedURLString: String? = nil) {
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
}
