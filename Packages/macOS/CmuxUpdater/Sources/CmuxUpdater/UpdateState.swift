public import Foundation
@preconcurrency public import Sparkle

/// The current phase of the custom (non-Sparkle-UI) update flow, with the per-phase payload
/// needed to advance, cancel, or describe it.
///
/// `UpdateState` is the single value the update UI renders from and the update controller
/// reacts to. Each case carries the Sparkle callbacks for that phase (e.g. ``UpdateAvailable``
/// carries the reply that installs or dismisses the found update). Values are created and read
/// on the main actor and never cross an actor boundary, so the embedded non-`Sendable`
/// closures are safe.
public enum UpdateState: Equatable {
    /// No update activity; the pill is hidden unless a background update was detected.
    case idle
    /// Sparkle is asking whether to enable automatic checks (cmux suppresses this UI).
    case permissionRequest(PermissionRequest)
    /// A requested check is waiting for updater readiness or an older Sparkle cycle to finish.
    case preparingCheck(Checking)
    /// A check is in progress.
    case checking(Checking)
    /// An update was found and is awaiting the user's install/dismiss choice.
    case updateAvailable(UpdateAvailable)
    /// A check finished with no update available.
    case notFound(NotFound)
    /// A check or install failed.
    case error(Error)
    /// The user accepted the freshly resolved update and Sparkle is starting its download.
    case startingDownload
    /// The update payload is downloading.
    case downloading(Downloading)
    /// The downloaded payload is being extracted/prepared.
    case extracting(Extracting)
    /// The update is installing (and may relaunch the app).
    case installing(Installing)

    /// Whether this is the ``idle`` case.
    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    /// Whether an update prompt is currently available to install.
    ///
    /// Progress states are deliberately excluded. Advertising another install action while a
    /// check or install is already running makes the menu claim an action that will be ignored.
    public var isInstallable: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    /// Invokes the phase-appropriate cancellation/acknowledgement callback.
    @MainActor public func cancel() {
        switch self {
        case .preparingCheck(let checking), .checking(let checking):
            checking.cancel()
        case .updateAvailable(let available):
            available.dismiss()
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

    /// Causally completes a Sparkle prompt/check after a newer visible state supersedes it.
    @MainActor func finishAsSuperseded() {
        switch self {
        case .preparingCheck(let checking), .checking(let checking):
            checking.cancelAsSuperseded()
        case .updateAvailable(let available):
            available.reply.consume(.dismiss, source: .superseded)
        case .notFound(let notFound):
            notFound.acknowledgement()
        default:
            break
        }
    }

    public static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.permissionRequest, .permissionRequest):
            return true
        case (.preparingCheck, .preparingCheck):
            return true
        case (.checking, .checking):
            return true
        case (.updateAvailable(let lUpdate), .updateAvailable(let rUpdate)):
            return lUpdate.appcastItem.displayVersionString == rUpdate.appcastItem.displayVersionString
        case (.notFound(let lResult), .notFound(let rResult)):
            return lResult.reason == rResult.reason
        case (.error(let lErr), .error(let rErr)):
            return lErr.error.localizedDescription == rErr.error.localizedDescription
        case (.startingDownload, .startingDownload):
            return true
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

    /// Payload for ``UpdateState/notFound(_:)``.
    public struct NotFound {
        /// Identity for matching delayed presentation and dismissal work to this exact result.
        let id = UUID()
        /// Sparkle's authoritative reason that no installable update was returned.
        public enum Reason: Equatable {
            /// The installed build matches the latest build in the appcast.
            case upToDate
            /// The installed build is newer than the latest build in the appcast.
            case newerThanLatest(latestVersion: String?)
            /// The newest update requires a newer macOS version.
            case systemTooOld(latestVersion: String?, minimumSystemVersion: String?)
            /// The newest update does not support this macOS version.
            case systemTooNew(latestVersion: String?, maximumSystemVersion: String?)
            /// The newest update requires Apple silicon.
            case unsupportedHardware(latestVersion: String?)
            /// Development and staging builds do not participate in the public update channel.
            case developmentBuild
            /// Sparkle did not provide a reason that cmux understands.
            case unknown
        }

        /// Why no update can be offered.
        public let reason: Reason
        /// Tells Sparkle the "no update" result was acknowledged/dismissed.
        public let acknowledgement: () -> Void

        /// Creates the payload.
        ///
        /// - Parameter reason: The authoritative reason no update can be offered.
        /// - Parameter acknowledgement: Tells Sparkle the result was acknowledged.
        public init(reason: Reason = .upToDate, acknowledgement: @escaping () -> Void) {
            self.reason = reason
            self.acknowledgement = acknowledgement
        }

        /// Whether this low-information success may disappear after the standard short delay.
        /// Compatibility, development-build, and unknown results stay visible until acknowledged.
        public var automaticallyDismisses: Bool {
            switch reason {
            case .upToDate, .newerThanLatest:
                return true
            case .systemTooOld, .systemTooNew, .unsupportedHardware, .developmentBuild, .unknown:
                return false
            }
        }

        /// A truthful localized title for this result.
        public var title: String {
            switch reason {
            case .upToDate:
                return String(localized: "update.notFound.upToDate.title", defaultValue: "No Updates Available")
            case .newerThanLatest:
                return String(localized: "update.notFound.newerThanLatest.title", defaultValue: "No Update Needed")
            case .systemTooOld, .systemTooNew, .unsupportedHardware:
                return String(localized: "update.notFound.incompatible.title", defaultValue: "Update Not Compatible")
            case .developmentBuild:
                return String(localized: "update.notFound.development.title", defaultValue: "Updates Unavailable for This Build")
            case .unknown:
                return String(localized: "update.notFound.unknown.title", defaultValue: "Update Status Unknown")
            }
        }

        /// A truthful localized explanation for this result.
        public var message: String {
            switch reason {
            case .upToDate:
                return String(
                    localized: "update.notFound.upToDate.message",
                    defaultValue: "You are running the latest version currently available."
                )
            case .newerThanLatest(let latestVersion):
                if let latestVersion, !latestVersion.isEmpty {
                    return String(
                        localized: "update.notFound.newerThanLatest.withVersion.message",
                        defaultValue: "This cmux build is newer than the latest published version (\(latestVersion))."
                    )
                }
                return String(
                    localized: "update.notFound.newerThanLatest.message",
                    defaultValue: "This cmux build is newer than the latest published version."
                )
            case .systemTooOld(let latestVersion, let minimumSystemVersion):
                if let latestVersion, !latestVersion.isEmpty,
                   let minimumSystemVersion, !minimumSystemVersion.isEmpty {
                    return String(
                        localized: "update.notFound.systemTooOld.withVersions.message",
                        defaultValue: "cmux \(latestVersion) requires macOS \(minimumSystemVersion) or later. Upgrade macOS, then try again."
                    )
                }
                return String(
                    localized: "update.notFound.systemTooOld.message",
                    defaultValue: "The latest cmux update requires a newer version of macOS. Upgrade macOS, then try again."
                )
            case .systemTooNew(let latestVersion, let maximumSystemVersion):
                if let latestVersion, !latestVersion.isEmpty,
                   let maximumSystemVersion, !maximumSystemVersion.isEmpty {
                    return String(
                        localized: "update.notFound.systemTooNew.withVersions.message",
                        defaultValue: "cmux \(latestVersion) supports macOS through \(maximumSystemVersion). Try again when a compatible version is published."
                    )
                }
                return String(
                    localized: "update.notFound.systemTooNew.message",
                    defaultValue: "The latest cmux update does not support this macOS version. Try again when a compatible version is published."
                )
            case .unsupportedHardware(let latestVersion):
                if let latestVersion, !latestVersion.isEmpty {
                    return String(
                        localized: "update.notFound.unsupportedHardware.withVersion.message",
                        defaultValue: "cmux \(latestVersion) requires a Mac with Apple silicon."
                    )
                }
                return String(
                    localized: "update.notFound.unsupportedHardware.message",
                    defaultValue: "The latest cmux update requires a Mac with Apple silicon."
                )
            case .developmentBuild:
                return String(
                    localized: "update.notFound.development.message",
                    defaultValue: "Development and staging builds do not receive updates from the public release channel."
                )
            case .unknown:
                return String(
                    localized: "update.notFound.unknown.message",
                    defaultValue: "cmux could not determine whether a compatible update is available. Try again."
                )
            }
        }
    }

    /// Payload for ``UpdateState/permissionRequest(_:)``.
    public struct PermissionRequest {
        /// The Sparkle permission request being answered.
        public let request: SPUUpdatePermissionRequest
        /// Replies to Sparkle's permission prompt.
        public let reply: @Sendable (SUUpdatePermissionResponse) -> Void

        /// Creates the payload.
        public init(request: SPUUpdatePermissionRequest, reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
            self.request = request
            self.reply = reply
        }
    }

    /// Payload for ``UpdateState/checking(_:)``.
    public struct Checking {
        private let cancellationHandler: (UpdateCheckCancellationSource) -> Void

        /// Creates the payload.
        ///
        /// - Parameter cancel: Cancels the in-progress check.
        public init(cancel: @escaping () -> Void) {
            self.cancellationHandler = { _ in cancel() }
        }

        init(cancellationHandler: @escaping (UpdateCheckCancellationSource) -> Void) {
            self.cancellationHandler = cancellationHandler
        }

        /// Cancels a check at the user's request.
        public func cancel() {
            cancellationHandler(.user)
        }

        /// Cancels a superseded check without treating the controller transition as user intent.
        func cancelAsSuperseded() {
            cancellationHandler(.superseded)
        }
    }

    /// Payload for ``UpdateState/updateAvailable(_:)``.
    public struct UpdateAvailable {
        /// The appcast item describing the available update.
        public let appcastItem: SUAppcastItem
        /// The one-shot Sparkle reply. Kept internal so external UI cannot bypass the
        /// controller-owned install-latest flow with a captured appcast item.
        let reply: UpdatePromptReply

        /// Creates the payload.
        @MainActor public init(appcastItem: SUAppcastItem, reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
            self.appcastItem = appcastItem
            self.reply = UpdatePromptReply(reply)
        }

        init(appcastItem: SUAppcastItem, reply: UpdatePromptReply) {
            self.appcastItem = appcastItem
            self.reply = reply
        }

        /// Skips this version in Sparkle.
        @MainActor public func skip() {
            reply(.skip)
        }

        /// Dismisses this prompt without installing its captured appcast item.
        @MainActor public func dismiss() {
            reply(.dismiss)
        }

        /// A link to the release notes for this update. Appcast metadata is authoritative; the
        /// version-derived GitHub URL is a fallback for older feeds without a notes link.
        public var releaseNotes: ReleaseNotes? {
            ReleaseNotes(appcastItem: appcastItem)
        }
    }

    /// A "view release notes" link derived from an update's display version string.
    public enum ReleaseNotes {
        /// The version maps to a git commit; links to the commit page.
        case commit(URL)
        /// The version maps to a semantic-version tag; links to the release page.
        case tagged(URL)

        /// Resolves release notes from an appcast item. The feed's explicit URL is authoritative;
        /// deriving a GitHub URL from the display version only supports older feeds.
        public init?(appcastItem: SUAppcastItem) {
            if let appcastURL = appcastItem.fullReleaseNotesURL ?? appcastItem.releaseNotesURL {
                self = .tagged(appcastURL)
                return
            }
            self.init(displayVersionString: appcastItem.displayVersionString)
        }

        /// Derives a release-notes link from a display version string, returning `nil` when
        /// the string contains neither a semantic version nor a git hash.
        public init?(displayVersionString: String) {
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

        /// The destination URL of the release-notes link.
        public var url: URL {
            switch self {
            case .commit(let url): return url
            case .tagged(let url): return url
            }
        }

        /// The localized label for the release-notes link.
        public var label: String {
            switch self {
            case .commit: return String(localized: "update.viewGitHubCommit", defaultValue: "View GitHub Commit")
            case .tagged: return String(localized: "update.viewReleaseNotes", defaultValue: "View Release Notes")
            }
        }
    }

    /// Payload for ``UpdateState/error(_:)``.
    public struct Error {
        /// The underlying error.
        public let error: any Swift.Error
        /// Retries the failed operation.
        public let retry: () -> Void
        /// Dismisses the error.
        public let dismiss: () -> Void
        /// Extra technical detail captured at failure time, surfaced in the error popover.
        public let technicalDetails: String?
        /// The feed URL in effect when the error occurred, surfaced in the error popover.
        public let feedURLString: String?

        /// Creates the payload.
        public init(error: any Swift.Error,
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

    /// Payload for ``UpdateState/downloading(_:)``.
    public struct Downloading {
        /// Cancels the download.
        public let cancel: () -> Void
        /// Total expected byte count, when known.
        public let expectedLength: UInt64?
        /// Bytes received so far.
        public let progress: UInt64

        /// Creates the payload.
        public init(cancel: @escaping () -> Void, expectedLength: UInt64?, progress: UInt64) {
            self.cancel = cancel
            self.expectedLength = expectedLength
            self.progress = progress
        }
    }

    /// Payload for ``UpdateState/extracting(_:)``.
    public struct Extracting {
        /// Extraction progress in `0...1`.
        public let progress: Double

        /// Creates the payload.
        public init(progress: Double) {
            self.progress = progress
        }
    }

    /// Payload for ``UpdateState/installing(_:)``.
    public struct Installing {
        /// Whether this install was triggered by Sparkle's automatic "install on quit" path
        /// rather than an explicit user action.
        public var isAutoUpdate = false
        /// Retries terminating the app so the install can finish.
        public let retryTerminatingApplication: () -> Void
        /// Dismisses the installing state.
        public let dismiss: () -> Void

        /// Creates the payload.
        public init(isAutoUpdate: Bool = false,
                    retryTerminatingApplication: @escaping () -> Void,
                    dismiss: @escaping () -> Void) {
            self.isAutoUpdate = isAutoUpdate
            self.retryTerminatingApplication = retryTerminatingApplication
            self.dismiss = dismiss
        }
    }
}
