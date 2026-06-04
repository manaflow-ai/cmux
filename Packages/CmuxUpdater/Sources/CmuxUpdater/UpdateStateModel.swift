public import Foundation
@preconcurrency public import Sparkle
import Observation

/// The observable source of truth for the custom update UI.
///
/// `UpdateStateModel` holds the current ``UpdateState`` (plus an optional `overrideState` used
/// by debug tooling), the most recently detected background update, and a set of derived,
/// localized display strings the UI renders. It is observed directly by SwiftUI via the
/// Observation framework; appearance (color) derivations live in the `CmuxUpdaterUI` package.
///
/// State transitions funnel through ``setState(_:)`` / ``setOverrideState(_:)`` (and the
/// higher-level mutators), which both apply the change and emit on the ``stateChanges()``
/// stream. ``UpdateController`` consumes that stream to drive force-install, attempt-update,
/// and the auto-dismiss of a "no updates" result — replacing the previous Combine
/// `@Published` subscriptions.
///
/// All access is main-actor isolated; ``UpdateState`` values never cross an actor boundary, so
/// the non-`Sendable` callbacks they carry are safe.
@MainActor
@Observable
public final class UpdateStateModel {
    /// The current update phase as driven by Sparkle.
    public private(set) var state: UpdateState = .idle
    /// A debug/override phase that, when set, takes precedence over ``state`` for display.
    public private(set) var overrideState: UpdateState?
    /// The display version of the most recently detected background update, if any.
    public private(set) var detectedUpdateVersion: String?
    /// The appcast item for the most recently detected background update, if any.
    public private(set) var detectedUpdateItem: SUAppcastItem?
    #if DEBUG
    /// A debug override for the pill's title text.
    public var debugOverrideText: String?
    #endif

    /// Continuations for active ``stateChanges()`` subscribers, keyed by subscription id.
    @ObservationIgnored
    private var changeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Creates an empty model in the ``UpdateState/idle`` state.
    public init() {}

    // MARK: - Change stream

    /// A stream that emits once whenever ``state`` or ``overrideState`` changes.
    ///
    /// The element is `Void`: subscribers read the latest ``state``/``overrideState`` directly
    /// (both are main-actor isolated like the subscriber), which avoids sending the
    /// non-`Sendable` ``UpdateState`` across the stream. This is the `@Observable`-native
    /// replacement for observing `@Published var state`.
    public func stateChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            changeObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.changeObservers[id] = nil }
            }
        }
    }

    private func notifyStateChanged() {
        for continuation in changeObservers.values {
            continuation.yield(())
        }
    }

    // MARK: - State mutation (the single write funnel)

    /// Sets ``state`` and notifies ``stateChanges()`` subscribers.
    public func setState(_ newState: UpdateState) {
        state = newState
        notifyStateChanged()
    }

    /// Sets ``overrideState`` and notifies ``stateChanges()`` subscribers.
    public func setOverrideState(_ newState: UpdateState?) {
        overrideState = newState
        notifyStateChanged()
    }

    /// Applies a state produced by the Sparkle driver, recording the detected update first
    /// when the new state is ``UpdateState/updateAvailable(_:)``.
    public func applyDriverState(_ newState: UpdateState) {
        if case .updateAvailable(let update) = newState {
            recordDetectedUpdate(update.appcastItem)
        }
        setState(newState)
    }

    /// Cancels whatever phase is active and returns the model to ``UpdateState/idle``,
    /// clearing any override. Used when starting a fresh check.
    public func cancelActiveStateForNewCheck() {
        state.cancel()
        // One conceptual transition: update both fields, then emit a single change notification
        // (avoids two redundant stateChanges() emissions for one logical reset).
        state = .idle
        overrideState = nil
        notifyStateChanged()
    }

    // MARK: - Detected background update

    /// Records a background-detected available update (or clears it when the version string
    /// is unusable).
    public func recordDetectedUpdate(_ item: SUAppcastItem) {
        let version = Self.normalizedDetectedUpdateVersion(from: item.displayVersionString)
        detectedUpdateItem = version == nil ? nil : item
        detectedUpdateVersion = version
    }

    /// Clears any detected background update.
    public func clearDetectedUpdate() {
        detectedUpdateItem = nil
        detectedUpdateVersion = nil
    }

    #if DEBUG
    /// Sets the detected-update version directly without an appcast item. DEBUG-only, for UI
    /// test scaffolding that wants to surface the passive banner without a real appcast.
    public func debugSetDetectedVersion(_ version: String?) {
        detectedUpdateItem = nil
        detectedUpdateVersion = version
    }
    #endif

    /// Dismisses a detected available update, replying `.dismiss` to Sparkle for whichever of
    /// ``state``/``overrideState`` is carrying it, and clearing the detected-update banner.
    public func dismissDetectedAvailableUpdate() {
        clearDetectedUpdate()

        var didDismissUpdate = false
        if case .updateAvailable(let update) = state {
            update.reply(.dismiss)
            didDismissUpdate = true
            setState(.idle)
        }

        if let overrideState, case .updateAvailable(let update) = overrideState {
            if !didDismissUpdate {
                update.reply(.dismiss)
            }
            setOverrideState(nil)
        }
    }

    // MARK: - Derived display state

    /// The phase to display: the override if present, otherwise ``state``.
    public var effectiveState: UpdateState {
        overrideState ?? state
    }

    /// Whether to surface a passive "update available" banner detected in the background while
    /// the foreground flow is idle.
    public var showsDetectedBackgroundUpdate: Bool {
        effectiveState.isIdle && detectedUpdateVersion != nil
    }

    /// Whether cached appcast details exist for the detected background update.
    public var hasCachedDetectedUpdateDetails: Bool {
        detectedUpdateItem != nil
    }

    /// Whether the update pill should be visible.
    public var showsPill: Bool {
        !effectiveState.isIdle || showsDetectedBackgroundUpdate
    }

    /// The pill's title text for the current phase.
    public var text: String {
        #if DEBUG
        if let debugOverrideText { return debugOverrideText }
        #endif
        if let detectedText = detectedUpdateText {
            return detectedText
        }
        switch effectiveState {
        case .idle:
            return ""
        case .permissionRequest:
            return String(localized: "update.permissionRequest.text", defaultValue: "Enable Automatic Updates?")
        case .checking:
            return String(localized: "update.checking", defaultValue: "Checking for Updates…")
        case .updateAvailable(let update):
            let version = update.appcastItem.displayVersionString
            if !version.isEmpty {
                return String(localized: "update.available.withVersion", defaultValue: "Update Available: \(version)")
            }
            return String(localized: "update.available.short", defaultValue: "Update Available")
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                let progress = Double(download.progress) / Double(expectedLength)
                let percent = String(format: "%.0f%%", progress * 100)
                return String(localized: "update.downloading.progress", defaultValue: "Downloading: \(percent)")
            }
            return String(localized: "update.downloading.status", defaultValue: "Downloading…")
        case .extracting(let extracting):
            let percent = String(format: "%.0f%%", extracting.progress * 100)
            return String(localized: "update.extracting.progress", defaultValue: "Preparing: \(percent)")
        case .installing(let install):
            return install.isAutoUpdate ? String(localized: "update.restartToComplete", defaultValue: "Restart to Complete Update") : String(localized: "update.installing.status", defaultValue: "Installing…")
        case .notFound:
            return String(localized: "update.noUpdates.title", defaultValue: "No Updates Available")
        case .error(let err):
            return Self.userFacingErrorTitle(for: err.error)
        }
    }

    /// The widest title text the pill can show for the current phase, used to reserve layout
    /// width so the pill does not resize as progress ticks.
    public var maxWidthText: String {
        if let detectedText = detectedUpdateText {
            return detectedText
        }
        switch effectiveState {
        case .downloading:
            return "Downloading: 100%"
        case .extracting:
            return "Preparing: 100%"
        default:
            return text
        }
    }

    /// The SF Symbol name for the current phase, or `nil` when idle.
    public var iconName: String? {
        if showsDetectedBackgroundUpdate {
            return "shippingbox.fill"
        }
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

    /// A one-line description of the current phase for the popover.
    public var description: String {
        switch effectiveState {
        case .idle:
            return ""
        case .permissionRequest:
            return String(localized: "update.configureAutoUpdates", defaultValue: "Configure automatic update preferences")
        case .checking:
            return String(localized: "update.pleaseWait", defaultValue: "Please wait while we check for available updates")
        case .updateAvailable(let update):
            return update.releaseNotes?.label ?? String(localized: "update.downloadAndInstall", defaultValue: "Download and install the latest version")
        case .downloading:
            return String(localized: "update.downloadingPackage", defaultValue: "Downloading the update package")
        case .extracting:
            return String(localized: "update.preparingUpdate", defaultValue: "Extracting and preparing the update")
        case let .installing(install):
            return install.isAutoUpdate ? String(localized: "update.restartToComplete", defaultValue: "Restart to Complete Update") : String(localized: "update.installingAndRestarting", defaultValue: "Installing update and preparing to restart")
        case .notFound:
            return String(localized: "update.noUpdates.message", defaultValue: "You are running the latest version")
        case .error(let err):
            return Self.userFacingErrorMessage(for: err.error)
        }
    }

    /// A short trailing badge (version or percent) for the current phase, or `nil`.
    public var badge: String? {
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

    /// The detected-background-update title, when one should be shown.
    var detectedUpdateText: String? {
        guard showsDetectedBackgroundUpdate, let version = detectedUpdateVersion else { return nil }
        return String(localized: "update.available.withVersion", defaultValue: "Update Available: \(version)")
    }

    // MARK: - Error formatting

    /// A short, user-facing title for an update error.
    public static func userFacingErrorTitle(for error: any Swift.Error) -> String {
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

    /// A user-facing explanatory message for an update error.
    public static func userFacingErrorMessage(for error: any Swift.Error) -> String {
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
        // Catch-all: keep user-facing copy in cmux terms; raw vendor descriptions, domains, and
        // codes stay in `errorDetails` (the copyable Details block + the update log), not here.
        return String(localized: "update.error.failed.message", defaultValue: "Something went wrong while checking for updates. Try again, or check the update log for details.")
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

    /// Normalizes a Sparkle display version into a trimmed, non-empty string, or `nil`.
    public static func normalizedDetectedUpdateVersion(from version: String) -> String? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
