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

    /// A staged build known pulled waits in Update Ready (an installer this app cannot cancel, or
    /// one about to be dropped): no card or footer pill offers it, and a quit cancels it instead
    /// of installing it when this app holds its installer.
    var stagedPulledHeld: Bool {
        guard case .ready = flow.phase, let staged = stagedBuild(), !staged.isEmpty else { return false }
        return isKnownPulled(staged)
    }

    /// Starts the check that downloads the newest build (this app's driver, never Sparkle's silent one).
    func startNewestCheck(_ reason: NewestFetch) {
        guard reason == .click || !isOffManagedChannel else { return }
        newestFetch = reason
        if let startCheck = stagedRefresh.startCheck { startCheck() } else { controller?.checkForUpdates() }
    }

    /// Whether `build` is known pulled: on the pulled list as last read, or dropped as pulled before.
    func isKnownPulled(_ build: String) -> Bool {
        pulledWatch.isPulled(build) || droppedPulled.contains(build)
    }

    /// A found update known pulled is never offered or downloaded: ``indicatorPhase`` hides it (no
    /// card, no Update Available button, no download), and its Sparkle prompt ends without
    /// skipping it, so the next check offers a good build as usual.
    func dropPulledAvailable() {
        guard case .available = sourcePhase, let found = availableBuild(), isKnownPulled(found) else { return }
        log.append("found build \(found) was pulled: not offering it")
        dismissAvailable()
    }

    /// The pulled list was read, or a build was staged or found: a pulled staged build gives way to
    /// the newest good one, and a pulled running build updates to it.
    func followPulled() {
        // A found build the list now marks pulled leaves the update-found step before anything accepts it.
        if case .available = flow.phase, let found = availableBuild(), isKnownPulled(found) { return syncFlowPhase() }
        guard disabledReason == nil, newestFetch == nil, !pulledWatch.pulledBuilds.isEmpty else { return }
        // A pulled staged build this app holds no installer for stays: a pulled running build still updates.
        var pulledStagedKept = false
        if case .ready = flow.phase, let staged = stagedBuild(), !staged.isEmpty, pulledWatch.isPulled(staged) {
            // An install click decides for itself (``StagedUpdateRefresh/beforeInstall(updater:install:)``).
            guard !flow.installRequested, !stagedRefresh.clickWaits else { return }
            if cancelStaged() {
                if droppedPulled.insert(staged).inserted {
                    log.append("staged build \(staged) was pulled: dropping it and getting the newest build")
                    let runningPulled = pulledWatch.isPulled(identity.build)
                    if runningPulled { runningPulledHandled = true }
                    startNewestCheck(runningPulled ? .runningPulled : .stagedPulled)
                } else {
                    // The feed staged it again (a cached appcast): drop it and wait for the next scheduled check.
                    log.append("staged build \(staged) was pulled and staged again: dropped")
                }
                return
            }
            pulledStagedKept = true
        }
        guard !isOffManagedChannel, pulledWatch.isPulled(identity.build), !runningPulledHandled else { return }
        switch flow.phase {
        case .hidden, .note:
            runningPulledHandled = true
            log.append("running build \(identity.build) was pulled: getting the newest build")
            startNewestCheck(.runningPulled)
        case .ready where pulledStagedKept:
            runningPulledHandled = true
            log.append("running build \(identity.build) and staged build \(stagedBuild() ?? "") were pulled, and no installer was held to cancel: getting the newest build")
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
            if fetch != .click {
                if isOffManagedChannel { newestFetch = nil } else { acceptAvailable() }
            }
        case .checking, .downloading:
            break
        case .hidden:
            // The staged build's cancel passes through hidden before the check starts.
            if previous == .checking || previous.isDownloading { newestFetch = nil }
        case .ready, .installing, .note:
            newestFetch = nil
        }
    }

    /// `debug.updater {action: "newest", pulled?}`: shows the "Getting the Newest Build…" card
    /// halfway through its download, as a stale or pulled build's replacement shows it (captures).
    public func debugShowGettingNewest(pulled: Bool) {
        newestFetch = pulled ? .runningPulled : .click
        debugIndicatorPhase = .downloading(UpdateTransfer(stage: .downloading, fraction: 0.4))
    }
}
