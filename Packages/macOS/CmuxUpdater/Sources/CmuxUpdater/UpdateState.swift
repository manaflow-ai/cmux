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
    /// A check is in progress.
    case checking(Checking)
    /// An update was found and is awaiting the user's install/dismiss choice.
    case updateAvailable(UpdateAvailable)
    /// A check finished with no update available.
    case notFound(NotFound)
    /// A check or install failed.
    case error(Error)
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

    /// Whether this is the ``installing(_:)`` case.
    public var isInstalling: Bool {
        if case .installing = self { return true }
        return false
    }

    /// Whether the flow is in a phase that the "force install" path can drive to completion
    /// by repeatedly confirming (checking through installing).
    public var isInstallable: Bool {
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

    /// Invokes the phase-appropriate cancellation/acknowledgement callback.
    public func cancel() {
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

    /// Confirms the current phase, installing the update when one is available.
    public func confirm() {
        switch self {
        case .updateAvailable(let available):
            available.reply(.install)
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
                && lInstall.stagedVersion == rInstall.stagedVersion
        default:
            return false
        }
    }

    /// Payload for ``UpdateState/notFound(_:)``.
    public struct NotFound {
        /// Tells Sparkle the "no update" result was acknowledged/dismissed.
        public let acknowledgement: () -> Void

        /// Creates the payload.
        public init(acknowledgement: @escaping () -> Void) {
            self.acknowledgement = acknowledgement
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
        /// Cancels the in-progress check.
        public let cancel: () -> Void

        /// Creates the payload.
        public init(cancel: @escaping () -> Void) {
            self.cancel = cancel
        }
    }

    /// Payload for ``UpdateState/updateAvailable(_:)``.
    public struct UpdateAvailable {
        /// The appcast item describing the available update.
        public let appcastItem: SUAppcastItem
        /// Replies to Sparkle with the user's install/dismiss choice.
        public let reply: @Sendable (SPUUserUpdateChoice) -> Void

        /// Creates the payload.
        public init(appcastItem: SUAppcastItem, reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
            self.appcastItem = appcastItem
            self.reply = reply
        }

        /// A link to the release notes for this update, derived from its version string.
        public var releaseNotes: ReleaseNotes? {
            ReleaseNotes(displayVersionString: appcastItem.displayVersionString)
        }
    }

    /// A "view release notes" link derived from an update's display version string.
    public enum ReleaseNotes {
        /// The version maps to a git commit; links to the commit page.
        case commit(URL)
        /// The version maps to a semantic-version tag; links to the release page.
        case tagged(URL)

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
        /// The display version of the update staged for install, when known (the auto-download
        /// path knows it from the appcast item; the user-driven path leaves it `nil`).
        public var stagedVersion: String?
        /// Retries terminating the app so the install can finish.
        public let retryTerminatingApplication: () -> Void
        /// Dismisses the installing state.
        public let dismiss: () -> Void

        /// Creates the payload.
        public init(isAutoUpdate: Bool = false,
                    stagedVersion: String? = nil,
                    retryTerminatingApplication: @escaping () -> Void,
                    dismiss: @escaping () -> Void) {
            self.isAutoUpdate = isAutoUpdate
            self.stagedVersion = stagedVersion
            self.retryTerminatingApplication = retryTerminatingApplication
            self.dismiss = dismiss
        }

        /// A link to the release notes for the staged update, when its version is known.
        public var releaseNotes: ReleaseNotes? {
            stagedVersion.flatMap { ReleaseNotes(displayVersionString: $0) }
        }
    }
}
