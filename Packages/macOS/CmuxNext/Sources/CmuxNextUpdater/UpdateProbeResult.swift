public import Foundation

/// What a feed offers this Mac, as Sparkle would decide it.
nonisolated public enum UpdateProbeOutcome: Sendable, Equatable {
    /// A newer build this macOS can run.
    case updateAvailable(AppcastItem)
    /// Nothing newer that this macOS can run, and nothing newer at all.
    /// `latest` is the newest item this macOS can run, if any.
    case upToDate(latest: AppcastItem?)
    /// A newer build exists but needs a newer macOS (a cmux-next build seen
    /// from macOS 14 or 15). This Mac stays on its current build, or on the
    /// newest compatible item when the feed still lists one.
    case requiresNewerSystem(AppcastItem, required: SystemVersion)

    public var kind: String {
        switch self {
        case .updateAvailable: "update_available"
        case .upToDate: "up_to_date"
        case .requiresNewerSystem: "requires_newer_macos"
        }
    }
}

/// One read-only check of a feed. Never downloads or installs anything.
nonisolated public struct UpdateProbeResult: Sendable, Equatable {
    public var track: UpdateTrack
    public var feedURL: String
    public var currentVersion: String
    public var currentBuild: String
    public var system: SystemVersion
    public var itemCount: Int
    public var outcome: UpdateProbeOutcome
    public var checkedAt: Date

    public init(track: UpdateTrack, feedURL: String, currentVersion: String, currentBuild: String, system: SystemVersion,
                itemCount: Int, outcome: UpdateProbeOutcome, checkedAt: Date) {
        self.track = track
        self.feedURL = feedURL
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.system = system
        self.itemCount = itemCount
        self.outcome = outcome
        self.checkedAt = checkedAt
    }
}
