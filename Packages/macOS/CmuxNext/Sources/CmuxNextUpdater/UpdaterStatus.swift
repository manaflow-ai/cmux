public import CmuxUpdater
import Foundation

/// A value snapshot of the updater for the control socket and tests.
nonisolated public struct UpdaterStatus: Sendable, Equatable {
    public var track: UpdateTrack
    public var bundleIdentifier: String?
    public var version: String
    public var build: String
    public var minimumSystemVersion: SystemVersion?
    public var system: SystemVersion
    public var feedURL: String
    /// Nil when Sparkle runs; else why it does not.
    public var sparkleDisabledReason: UpdateDisabledReason?
    /// Sparkle's `SUEnableAutomaticChecks` (the legacy app's setting).
    public var automaticChecks: Bool
    /// Sparkle's `SUAutomaticallyUpdate`.
    public var automaticDownloads: Bool
    /// ``UpdatePhase`` of the Sparkle flow; `idle` when Sparkle is off.
    public var phase: UpdatePhase
    /// Version of an update Sparkle found in the background, if any.
    public var detectedVersion: String?
    public var probing: Bool
    public var lastProbe: UpdateProbeResult?
    public var lastProbeError: String?
    public var channelSwitchTarget: AppChannelSwitchTarget?
    /// The test feed in use ("Use Test Update Feed"), or nil.
    public var testFeedURL: String? = nil
    /// The card above the footer (a check the user asked for), or nil.
    public var card: UpdateCard? = nil
    /// The footer pill's label ("Update Ready" for a staged update), or nil
    /// when it does not show.
    public var badge: String? = nil
}

/// The Sparkle flow's phase as a stable name for scripts.
nonisolated public enum UpdatePhase: String, Sendable, Codable {
    case idle
    case permissionRequest = "permission_request"
    case preparingCheck = "preparing_check"
    case checking
    case updateAvailable = "update_available"
    case notFound = "not_found"
    case error
    case startingDownload = "starting_download"
    case downloading
    case extracting
    case installing

    @MainActor
    public init(_ state: UpdateState) {
        switch state {
        case .idle: self = .idle
        case .permissionRequest: self = .permissionRequest
        case .preparingCheck: self = .preparingCheck
        case .checking: self = .checking
        case .updateAvailable: self = .updateAvailable
        case .notFound: self = .notFound
        case .error: self = .error
        case .startingDownload: self = .startingDownload
        case .downloading: self = .downloading
        case .extracting: self = .extracting
        case .installing: self = .installing
        }
    }
}
