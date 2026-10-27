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
    /// Starting, downloading or unpacking (``UpdateTransfer``): a progress
    /// ring, spinning while unmeasured.
    case downloading(UpdateTransfer)
    /// Found, not downloaded (`updates.downloadAutomatically` off): a click
    /// downloads and installs.
    case available(version: String?)
    /// Downloaded and waiting: the accent circle with a download glyph.
    /// A click installs and relaunches.
    case ready(version: String?)
    /// Installing and relaunching: a spinning ring and the Installing pill.
    case installing
    /// A check's result with nothing to install (up to date, check failed);
    /// the notice card shows it after the user asked.
    case note(UpdateNote)

    /// The Sparkle flow's phase. `version` names the update a background
    /// check accepted.
    @MainActor
    public init(_ state: UpdateState, version: String?) {
        switch state {
        case .idle, .permissionRequest:
            self = .hidden
        case .preparingCheck, .checking:
            // preparingCheck: a check the user asked for waits for the
            // running Sparkle session (a scheduled or silent one) to end.
            self = .checking
        case .updateAvailable(let available):
            // Only with `updates.downloadAutomatically` off: background
            // installs accept every other found update at once.
            self = .available(version: available.appcastItem.displayVersionString)
        case .notFound:
            self = .note(.upToDate)
        case .error:
            self = .note(.checkFailed)
        case .startingDownload:
            self = .downloading(.starting)
        case .downloading(let downloading):
            self = .downloading(.downloading(received: downloading.progress, expected: downloading.expectedLength))
        case .extracting(let extracting):
            self = .downloading(.preparing(extracting.progress > 0 ? extracting.progress : nil))
        case .installing(let installing):
            // Sparkle's "Restart to Complete Update" is the staged update, and so is an idle
            // install the relaunch gate holds: no waiting card, a click relaunches at once.
            self = installing.isAutoUpdate || installing.relaunchBlockers != nil ? .ready(version: version) : .installing
        }
    }

    /// A read-only probe (DEV builds), shown only after the user asked.
    public init(probe: UpdateProbeResult?, error: String?, probing: Bool) {
        if probing {
            self = .checking
        } else if error != nil {
            self = .note(.checkFailed)
        } else if let probe {
            switch probe.outcome {
            case .upToDate: self = .note(.upToDate)
            case .updateAvailable(let item): self = .note(.found(version: item.displayVersion))
            case .requiresNewerSystem(let item, let required):
                self = .note(.needsNewerMacOS(version: item.displayVersion, required: required.description))
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
        case .downloading(let transfer): transfer.stage == .preparing ? UpdaterStrings.preparing : UpdaterStrings.downloading
        case .ready(let version?) where !version.isEmpty: UpdaterStrings.available(version) + "\n" + UpdaterStrings.install
        case .ready, .available(nil): UpdaterStrings.availableNoVersion + "\n" + UpdaterStrings.install
        case .available(let version?): UpdaterStrings.available(version) + "\n" + UpdaterStrings.install
        case .installing: UpdaterStrings.installing
        case .note(let note): note.text
        }
    }

    /// Whether the ring spins: work with no measured progress.
    public var spins: Bool {
        switch self {
        case .checking, .installing: true
        case .downloading(let transfer): transfer.fraction == nil
        case .hidden, .available, .ready, .note: false
        }
    }

    /// The circle menu's titles.
    public static var installTitle: String { UpdaterStrings.install }
    public static var releaseNotesTitle: String { UpdaterStrings.releaseNotes }
}
