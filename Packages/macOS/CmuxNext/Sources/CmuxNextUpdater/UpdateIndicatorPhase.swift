public import CmuxUpdater
import Foundation
@preconcurrency import Sparkle

/// What the rail's update circle shows. cmux-next never opens an update
/// sheet: updates download in the background, a downloaded one waits as
/// the accent circle, and a check that finds nothing leaves a short note
/// beside the circle.
nonisolated public enum UpdateIndicatorPhase: Equatable, Sendable {
    /// Nothing to show.
    case hidden
    /// The user asked to check: a spinning ring.
    case checking
    /// Downloading or unpacking: a progress ring, nil while the size is
    /// unknown (spinning).
    case downloading(progress: Double?)
    /// Found, not downloaded (`updates.downloadAutomatically` off): a click
    /// downloads and installs.
    case available(version: String?)
    /// Downloaded and waiting: the accent circle with a download glyph.
    /// A click installs and relaunches.
    case ready(version: String?)
    /// Installing and relaunching: a spinning ring and the Installing pill.
    case installing
    /// A short note beside the circle (up to date, check failed), which
    /// hides itself.
    case note(String, isError: Bool)

    /// An update was found: downloading, downloaded and waiting, or
    /// installing (the Settings item's badge).
    public var isUpdateAvailable: Bool {
        switch self {
        case .available, .downloading, .ready, .installing: true
        case .hidden, .checking, .note: false
        }
    }

    /// Whether the circle shows.
    public var showsCircle: Bool {
        switch self {
        case .hidden, .note: false
        case .checking, .available, .downloading, .ready, .installing: true
        }
    }

    /// The Sparkle flow's phase. `version` names the update a background
    /// check accepted.
    @MainActor
    public init(_ state: UpdateState, version: String?) {
        switch state {
        case .idle, .permissionRequest, .preparingCheck:
            self = .hidden
        case .checking:
            self = .checking
        case .updateAvailable(let available):
            // Only with `updates.downloadAutomatically` off: background
            // installs accept every other found update at once.
            self = .available(version: available.appcastItem.displayVersionString)
        case .notFound:
            self = .note(UpdaterStrings.upToDate, isError: false)
        case .error:
            self = .note(UpdaterStrings.checkFailed, isError: true)
        case .startingDownload:
            self = .downloading(progress: nil)
        case .downloading(let downloading):
            let expected = downloading.expectedLength ?? 0
            self = .downloading(progress: expected > 0 ? min(1, Double(downloading.progress) / Double(expected)) : nil)
        case .extracting:
            self = .downloading(progress: nil)
        case .installing(let installing):
            // Sparkle's "Restart to Complete Update" is the staged update.
            self = installing.isAutoUpdate ? .ready(version: version) : .installing
        }
    }

    /// A read-only probe (DEV builds), shown only after the user asked.
    public init(probe: UpdateProbeResult?, error: String?, probing: Bool) {
        if probing {
            self = .checking
        } else if error != nil {
            self = .note(UpdaterStrings.checkFailed, isError: true)
        } else if let probe {
            switch probe.outcome {
            case .upToDate: self = .note(UpdaterStrings.upToDate, isError: false)
            case .updateAvailable(let item): self = .note(UpdaterStrings.available(item.displayVersion), isError: false)
            case .requiresNewerSystem(_, let required): self = .note(UpdaterStrings.needsNewerMacOS(required.description), isError: false)
            }
        } else {
            self = .hidden
        }
    }
}

extension UpdateIndicatorPhase {
    /// The circle's tooltip, or nil while hidden.
    public var toolTip: String? {
        switch self {
        case .hidden: nil
        case .checking: UpdaterStrings.checking
        case .downloading: UpdaterStrings.downloading
        case .ready(let version?) where !version.isEmpty: UpdaterStrings.available(version) + "\n" + UpdaterStrings.install
        case .ready, .available(nil): UpdaterStrings.availableNoVersion + "\n" + UpdaterStrings.install
        case .available(let version?): UpdaterStrings.available(version) + "\n" + UpdaterStrings.install
        case .installing: UpdaterStrings.installing
        case .note(let text, _): text
        }
    }

    /// The pill beside the circle, or nil when none shows.
    public var pillText: String? {
        switch self {
        case .installing: UpdaterStrings.installing
        case .note(let text, _): text
        case .hidden, .checking, .available, .downloading, .ready: nil
        }
    }

    /// Whether the ring spins: work with no measured progress.
    public var spins: Bool {
        switch self {
        case .checking, .installing, .downloading(progress: nil): true
        case .hidden, .available, .downloading, .ready, .note: false
        }
    }

    /// The circle menu's titles.
    public static var installTitle: String { UpdaterStrings.install }
    public static var releaseNotesTitle: String { UpdaterStrings.releaseNotes }
}
