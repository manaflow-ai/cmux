public import Foundation

/// The build Go back would take, as the card and the menu name it.
nonisolated public struct RevertTarget: Equatable, Sendable {
    public var build: String
    public var version: String
    /// `YYYY-MM-DD`, nil when not known.
    public var date: String?
    /// Kept on this Mac: going back is one relaunch, no download.
    public var kept: Bool

    public init(build: String, version: String, date: String?, kept: Bool) {
        self.build = build
        self.version = version
        self.date = date
        self.kept = kept
    }

    init(kept: KeptVersion) {
        self.init(build: kept.build, version: kept.shortVersion, date: kept.date, kept: true)
    }

    /// "nightly 4288034 from Nov 10", or the version alone without a date.
    public var label: String {
        let short = UpdateChangelog.cardVersion(version)
        guard let date, let day = Self.day(date) else { return short }
        return UpdaterStrings.versionFrom(short, day.formatted(.dateTime.month(.abbreviated).day()))
    }

    static func day(_ text: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

/// Going back, step by step, as the sidebar's notice card names it: progress that says what it is
/// doing (Leo 2026-11-11 asked for a better rollback UI).
nonisolated public struct RevertProgress: Equatable, Sendable {
    public enum Step: String, Equatable, Sendable {
        /// Reading the kept build and the stores' formats.
        case checking
        /// Nothing kept: reading the feed for the previous build.
        case finding
        /// Downloading a build that was not kept (``fraction``).
        case downloading
        /// Checking the download's signature.
        case verifying
        /// Putting the kept build in place.
        case swapping
        /// Quitting with every session kept, then opening the kept build.
        case restarting
        /// It did not run; ``failure`` says why.
        case failed
    }

    public var step: Step
    public var target: String?
    /// "nightly 4288034 from Nov 10" once known.
    public var label: String?
    public var fraction: Double?
    public var failure: String?

    public init(step: Step, target: String? = nil, label: String? = nil, fraction: Double? = nil, failure: String? = nil) {
        self.step = step
        self.target = target
        self.label = label
        self.fraction = fraction
        self.failure = failure
    }
}

/// The notice card while going back (``UpdaterService/revert``): what it is doing in the title's
/// words, the step on the detail line, the download's share as the bar.
nonisolated public struct RevertNotice: Equatable, Sendable {
    public var title: String
    public var detail: String?
    public var fraction: Double?
    /// Still going: the bar moves and the card has no x. A failure has an x and says why.
    public var working: Bool

    public init(_ progress: RevertProgress) {
        working = progress.step != .failed
        fraction = progress.fraction
        title = progress.step == .failed ? UpdaterStrings.revertFailed
            : progress.label.map(UpdaterStrings.revertGoingBack) ?? UpdaterStrings.revertGoingBackPlain
        detail = switch progress.step {
        case .checking: UpdaterStrings.revertChecking
        case .finding: UpdaterStrings.revertFinding
        case .downloading: progress.fraction.map { UpdaterStrings.revertDownloading + " " + $0.formatted(.percent.precision(.fractionLength(0))) }
            ?? UpdaterStrings.revertDownloading
        case .verifying: UpdaterStrings.revertVerifying
        case .swapping: UpdaterStrings.revertSwapping
        case .restarting: UpdaterStrings.revertRestarting
        case .failed: progress.failure
        }
    }
}

extension UpdaterService {
    /// The notice card's going-back state, nil when not going back.
    public var revertNotice: RevertNotice? { revert.map(RevertNotice.init) }
}
