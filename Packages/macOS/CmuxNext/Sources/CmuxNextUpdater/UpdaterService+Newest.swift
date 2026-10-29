import CmuxUpdater
import Foundation

/// Why the updater downloads the newest build in place of a staged or running one (Leo
/// 2026-10-29: "if there's multiple nightlies, i should only need to do one to get the latest").
nonisolated enum NewestFetch: Equatable, Sendable {
    /// Restart to Update found a build newer than the staged one, or the staged one was pulled:
    /// the click carries over to the newest build (``UpdaterService/installAfterSwap``).
    case click
    /// The staged build was pulled: it is dropped quietly and the newest good build downloads.
    case stagedPulled
    /// The running build was pulled: the newest good build downloads, and one line says why.
    case runningPulled
}

/// A pulled build is never offered, kept or installed: no banner and no rollback choice (Leo
/// 2026-10-29: "why the fuck am I even getting a thing that I can download that I can just— that
/// was pulled in the first place? Just fucking cancel it"). A staged pulled build is dropped and
/// the newest good build downloads in its place; a running pulled build downloads the newest good
/// one, and the Update Ready card asks before the relaunch, as every update does.
///
/// Stop condition and cleanup: ``newestFetch`` ends when the newest build is staged, the check
/// finds nothing or fails, or an install starts (``followNewestFetch(_:previous:)``). Each pulled
/// staged build is dropped once (``droppedPulled``), and the running build's own pull starts at
/// most one fetch per launch (``runningPulledHandled``), so a feed that still lists a pulled build
/// never loops. Nothing polls: this runs when the pulled list is read (launch, every update cycle,
/// the install click) and when a build is staged or found.
extension UpdaterService {
    /// The notice card while the newest build downloads in place of a stale or pulled one; nil
    /// otherwise, and while a pulled staged build is replaced (quietly).
    var newestCard: UpdateCard? {
        guard let newestFetch, newestFetch != .stagedPulled else { return nil }
        let pulled = newestFetch == .runningPulled
        switch flow.phase {
        case .hidden, .checking, .available: return .gettingNewest(nil, pulled: pulled)
        case .downloading(let transfer): return .gettingNewest(transfer, pulled: pulled)
        case .ready, .installing, .note: return nil
        }
    }

    /// Starts the check that downloads the newest build (this app's driver, never Sparkle's silent one).
    func startNewestCheck(_ reason: NewestFetch) {
        newestFetch = reason
        if let startCheck = stagedRefresh.startCheck { startCheck() } else { controller?.checkForUpdates() }
    }

    /// The pulled list was read, or a build was staged or found: a pulled staged build gives way to
    /// the newest good one, and a pulled running build updates to it.
    func followPulled() {
        guard disabledReason == nil, newestFetch == nil, !pulledWatch.pulledBuilds.isEmpty else { return }
        if case .ready = flow.phase, let staged = stagedBuild(), !staged.isEmpty, pulledWatch.isPulled(staged) {
            // An install click decides for itself (``StagedUpdateRefresh/beforeInstall(updater:install:)``).
            guard !flow.installRequested, !stagedRefresh.clickWaits, cancelStaged() else { return }
            if droppedPulled.insert(staged).inserted {
                log.append("staged build \(staged) was pulled: dropping it and getting the newest build")
                startNewestCheck(.stagedPulled)
            } else {
                // The feed staged it again (a cached appcast): drop it and wait for the next scheduled check.
                log.append("staged build \(staged) was pulled and staged again: dropped")
            }
            return
        }
        guard pulledWatch.isPulled(identity.build), !runningPulledHandled else { return }
        switch flow.phase {
        case .hidden, .note:
            runningPulledHandled = true
            log.append("running build \(identity.build) was pulled: getting the newest build")
            startNewestCheck(.runningPulled)
        case .available:
            runningPulledHandled = true
            log.append("running build \(identity.build) was pulled: downloading the newest build")
            newestFetch = .runningPulled
            acceptAvailable()
        case .checking, .downloading, .ready, .installing:
            break
        }
    }

    /// Follows the phase while the newest build downloads: a found build downloads (the person
    /// already chose to update), and the fetch ends once it is staged, or the check ends without one.
    func followNewestFetch(_ phase: UpdateIndicatorPhase, previous: UpdateIndicatorPhase) {
        guard let fetch = newestFetch else { return }
        switch phase {
        case .available:
            // The click's own request downloads it (``UpdateFlow``); a pulled build's replacement downloads here.
            if fetch != .click { acceptAvailable() }
        case .checking, .downloading:
            break
        case .hidden:
            // The staged build's cancel passes through hidden before the check starts.
            if previous == .checking || previous.isDownloading { newestFetch = nil }
        case .ready, .installing, .note:
            newestFetch = nil
        }
    }
}
