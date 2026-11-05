import Foundation
@preconcurrency import Sparkle

/// The `SPUUserDriver` that translates Sparkle's update lifecycle into ``UpdateStateModel``
/// transitions for cmux's custom (non-Sparkle-UI) update surface.
///
/// Sparkle's `SPUUserDriver`/`SPUUpdaterDelegate` are `@MainActor`, so every callback runs on
/// the main actor and writes the model directly with no thread hopping. A check's answer shows
/// the moment Sparkle reports it; the check timeout is a bounded, cancellable ``UpdateClock``
/// task. Host actions the
/// driver cannot perform itself (retry, relaunch prep) go through ``UpdateActionDelegate``.
@MainActor
final class UpdateDriver: NSObject, @preconcurrency SPUUserDriver {
    /// The state model this driver drives.
    let model: UpdateStateModel
    let log: any UpdateLogging
    private let clock: any UpdateClock
    let infoFeedURLProvider: () -> String?
    /// Whether the running build is a cmux DEV/staging build that is not on the public release
    /// train. When `true`, the driver must never surface the public appcast's update pill (see
    /// ``UpdateController/isDevLikeBundleIdentifier(_:)``).
    let isDevLikeBundle: Bool
    /// Host actions the driver delegates upward. Held weak; set by ``UpdateController``.
    weak var actionDelegate: (any UpdateActionDelegate)?
    /// Causal lifecycle signals consumed by ``UpdateController``.
    weak var eventDelegate: (any UpdateDriverEventDelegate)?

    private let checkTimeoutDuration: TimeInterval = UpdateTiming.checkTimeoutDuration
    private var checkTimeoutTask: Task<Void, Never>?
    private(set) var lastFeedURLString: String?
    /// Opt-in background installs (see `UpdateDriver+BackgroundInstall.swift`); off keeps the
    /// prompt-driven flow unchanged.
    var installsInBackground = false
    /// With background installs: whether a found update downloads without a click.
    var downloadsInBackground = true
    /// The automatic install whose app quits for it (``UpdateActionDelegate/updaterQuitsForAutomaticInstall(build:)``):
    /// Sparkle's held reply, kept until the app ends so a refused quit can stage it again.
    var quitInstall: (item: SUAppcastItem, install: () -> Void, cancel: (() -> Void)?)?
    /// The host's helper is quitting the app for ``quitInstall`` (``commitQuitInstall()``).
    var quitInstallCommitted = false
    /// Replaces the baked feed when set (``UpdateController/feedOverride``).
    var feedOverride: String?
    /// The release ring whose `sparkle:channel` tags are accepted (``UpdateController/ring``).
    var ring: UpdateRing = .nightly
    /// Builds at or below this are not offered (``UpdateController/skipsBuildsThrough``).
    var skipsBuildsThrough: String?
    /// Builds the host refuses (``UpdateController/refusesUpdate``).
    var refusesBuild: (@MainActor (String) -> Bool)?
    /// The host's bounded refusal-policy read, awaited before any item is accepted.
    var prepareUpdate: (@MainActor () async -> Void)?
    private var preparedOfferGeneration: UInt64 = 0
    private var preparedOfferReply: (@Sendable (SPUUserUpdateChoice) -> Void)?
    /// The update a background check accepted, and its held install once it is ready.
    var backgroundItem: SUAppcastItem?
    var stagedInstall: (() -> Void)?
    /// Bumped each time an update is staged, so a host's late release of an automatic install
    /// (``UpdateActionDelegate/updaterDefersAutomaticInstall(until:)``) only installs that update.
    var stagedGeneration: UInt64 = 0
    /// The automatic relaunch the host holds at Sparkle's relaunch, run once by its release or a click.
    var heldAutomaticRelaunch: InstallOnce?
    /// The update an automatic install handed to Sparkle, so a relaunch the host holds still names it
    /// as the staged update (``stagedItem``) and the indicator keeps its click.
    var automaticInstallItem: SUAppcastItem?
    /// Cancels the held installer (Skip on the ready prompt: no skipped version is recorded).
    var stagedCancel: (() -> Void)?
    var installsWhenStaged = false
    /// NIGHTLY hosts may install a staged update automatically once it is ready. Hosts that keep
    /// their daemon and sessions alive across an app relaunch set `holdsUserInstalls = false`;
    /// that contract also makes automatic installs immediate.
    var installsWhenIdle = false
    /// The install just handed to Sparkle came from the idle policy, not from the user, so its
    /// relaunch is subject to the quiet-input and daemon-mirror holds. Read once by
    /// ``handleShouldPostponeRelaunch(installHandler:)``.
    var relaunchIsAutomatic = false
    /// Whether this host uses the relaunch gate. cmux-next turns it off because its daemon keeps
    /// terminals, agents and running turns across the app relaunch. The flag applies to automatic
    /// installs too; a staged update must never wait behind live work on that host.
    var holdsUserInstalls = true
    /// The update Sparkle's own silent driver staged (`willInstallUpdateOnQuit`), which never
    /// reaches ``backgroundItem``; read only while its "Restart to Complete Update" state holds.
    var quitInstallItem: SUAppcastItem?
    /// The update whose relaunch the gate holds, so the host still names it as the staged
    /// update a click installs; read only while that held state is the model's.
    var heldRelaunchItem: SUAppcastItem?
    /// Holds a ready update's relaunch while agents are mid-turn or commands are running.
    let relaunchGate: UpdateRelaunchGate

    init(
        model: UpdateStateModel,
        log: any UpdateLogging,
        clock: any UpdateClock,
        isDevLikeBundle: Bool = false,
        relaunchAgentTimeout: Duration = UpdateRelaunchGate.agentTimeout,
        relaunchDaemonUnavailableTimeout: Duration = UpdateRelaunchGate.daemonUnavailableTimeout,
        infoFeedURLProvider: @escaping () -> String? = {
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        }
    ) {
        self.model = model
        self.log = log
        self.clock = clock
        self.infoFeedURLProvider = infoFeedURLProvider
        self.isDevLikeBundle = isDevLikeBundle
        self.relaunchGate = UpdateRelaunchGate(
            clock: clock, log: log, agentTimeout: relaunchAgentTimeout,
            daemonUnavailableTimeout: relaunchDaemonUnavailableTimeout)
        super.init()
    }

    deinit {
        checkTimeoutTask?.cancel()
    }

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_UI_TEST_TRIGGER_UPDATE_CHECK"] == "1" || env["CMUX_UI_TEST_AUTO_ALLOW_PERMISSION"] == "1" {
            log.append("auto-allow update permission (ui test)")
            Task { @MainActor in reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)) }
            return
        }
#endif
        // Never show Sparkle's permission UI. cmux always enables scheduled checks and keeps
        // automatic downloads disabled so installs remain user-driven.
        log.append("auto-allow update permission (no UI)")
        Task { @MainActor in reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)) }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        log.append("show user-initiated update check")
        beginChecking(cancel: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        invalidatePreparedOffer()
        if quitInstallItem?.versionString == appcastItem.versionString, installsInBackground {
            // Skip is the only public reply that cancels Sparkle's already-running silent
            // installer. Do not expose that reply as the ordinary staged/quit cancellation:
            // Sparkle records a skipped version here. After this cycle finishes, a fresh
            // foreground check clears Sparkle's skipped state and downloads through our own
            // driver, whose ready reply cancels without skipping the version (Sparkle 2.10).
            quitInstallItem = nil
            eventDelegate?.updateDriverNeedsSilentInstallResume()
            reply(.skip)
            return
        }
        guard let prepareUpdate else { return handleUpdateFound(appcastItem, reply: reply) }
        let generation = preparedOfferGeneration
        preparedOfferReply = reply
        Task { @MainActor [weak self] in
            await prepareUpdate()
            guard let self, self.preparedOfferGeneration == generation else { return }
            self.preparedOfferReply = nil
            self.handleUpdateFound(appcastItem, reply: reply)
        }
    }

    /// A policy read belongs to one check. Replacing/cancelling/ending that check releases its
    /// Sparkle reply at once; a later read completion cannot publish or download its old item.
    func invalidatePreparedOffer() {
        preparedOfferGeneration &+= 1
        let reply = preparedOfferReply
        preparedOfferReply = nil
        reply?(.dismiss)
    }

    private func handleUpdateFound(_ appcastItem: SUAppcastItem,
                                   reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        log.append("show update found: \(appcastItem.displayVersionString)")
        if let skip = skipsBuildsThrough, appcastItem.versionString.compare(skip, options: .numeric) != .orderedDescending {
            log.append("not offering \(appcastItem.versionString): a rollback left it (skips through \(skip))")
            setState(.idle)
            return reply(.dismiss)
        }
        // Before the background accept too: a refused build never downloads.
        if refusesBuild?(appcastItem.versionString) == true {
            log.append("not offering \(appcastItem.versionString): the host refuses it")
            setState(.idle)
            return reply(.dismiss)
        }
        let available = UpdateState.UpdateAvailable(appcastItem: appcastItem) { choice in reply(choice) }
        available.reply.onConsumed = { [weak self] reply, choice, source in
            self?.handlePromptReply(reply, choice: choice, source: source, item: appcastItem)
        }
        if installsInBackground && downloadsInBackground { return acceptInBackground(available) }
        setState(.updateAvailable(available))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // cmux uses Sparkle's UI for release notes links instead.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // Release notes are handled via link buttons.
    }

    func showUpdateNotFoundWithError(_ error: any Error,
                                     acknowledgement: @escaping () -> Void) {
        log.append("show update not found: \(formatErrorForLog(error))")
        // The answer shows the moment Sparkle has it, and Sparkle's session ends with it: a
        // check asked for while the note shows starts at once instead of queueing behind the
        // note's display time (update-check-PERF.md). The note's own dismissal has nothing
        // left to acknowledge.
        setState(.notFound(.init(acknowledgement: {})))
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void) {
        let details = formatErrorForLog(error)
        log.append("show updater error: \(details)")
        relaunchGate.cancel()
        endAutomaticInstallHold()
        setState(.error(.init(
            error: error,
            retry: { [weak self] in
                self?.model.setState(.idle)
                self?.actionDelegate?.updaterRequestsRetryCheckForUpdates()
            },
            dismiss: { [weak self] in
                self?.model.setState(.idle)
            },
            technicalDetails: details,
            feedURLString: lastFeedURLString
        )))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        log.append("show download initiated")
        setState(.downloading(.init(
            cancel: { [weak self] in
                cancellation()
                if case .downloading = self?.model.state {
                    self?.model.setState(.idle)
                }
            },
            expectedLength: nil,
            progress: 0)))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        log.append("download expected length: \(expectedContentLength)")
        guard case let .downloading(downloading) = model.state else {
            return
        }
        setState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: expectedContentLength,
            progress: 0)))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        log.append("download received data: \(length)")
        guard case let .downloading(downloading) = model.state else {
            return
        }
        setState(.downloading(.init(
            cancel: downloading.cancel,
            expectedLength: downloading.expectedLength,
            progress: downloading.progress + length)))
    }

    func showDownloadDidStartExtractingUpdate() {
        log.append("show extraction started")
        setState(.extracting(.init(progress: 0)))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        log.append(String(format: "show extraction progress: %.2f", progress))
        setState(.extracting(.init(progress: progress)))
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        log.append("show ready to install")
        if installsInBackground { return stageInBackground(reply) }
        reply(.install)
    }

    /// Sparkle asks this before every install that relaunches cmux: Install and Relaunch,
    /// Restart Now on the install-on-quit prompt, and a resumed install after Later. Returns
    /// `true` to hold the relaunch until `installHandler` is invoked (see ``UpdateRelaunchGate``).
    /// Hosts that preserve sessions set `holdsUserInstalls` to false, which bypasses every
    /// blocker, including automatic-install idle checks.
    func handleShouldPostponeRelaunch(item: SUAppcastItem? = nil, installHandler: @escaping () -> Void) -> Bool {
        let automatic = relaunchIsAutomatic
        relaunchIsAutomatic = false
        var isAutoUpdate = false
        if case .installing(let installing) = model.state { isAutoUpdate = installing.isAutoUpdate }
        // A session-preserving host can relaunch while agents and commands are live. Keep this
        // decision before reading the host mirror so a stale/unavailable mirror cannot turn an
        // app update into the old "Waiting to Relaunch" card.
        guard holdsUserInstalls else {
            // An automatic install checks the host's moment again here, at the relaunch itself: a
            // sheet or composition may have begun while Sparkle installed. A click never waits.
            if automatic, holdAutomaticRelaunch(installHandler) { return true }
            log.append("update relaunch is immediate; the daemon preserves live sessions (automatic=\(automatic))")
            return false
        }
        let reported = currentRelaunchBlockers()
        let blockers = automatic ? reported : reported.forUserInstall
        guard !blockers.isEmpty else { return false }
        heldRelaunchItem = item
        holdRelaunch(isAutoUpdate: isAutoUpdate, automatic: automatic, install: installHandler)
        return true
    }

    /// Asks the host to hold an automatic relaunch (``UpdateActionDelegate/updaterDefersAutomaticInstall(until:)``).
    /// While held, the update shows as staged and a click relaunches at once; either runs
    /// `installHandler` once. False when the host holds nothing.
    private func holdAutomaticRelaunch(_ installHandler: @escaping () -> Void) -> Bool {
        let once = InstallOnce(installHandler)
        guard actionDelegate?.updaterDefersAutomaticInstall(until: { [weak self] in
            guard let self, self.heldAutomaticRelaunch === once else { return }
            self.heldAutomaticRelaunch = nil
            self.automaticInstallItem = nil
            self.log.append("automatic relaunch: the host's hold ended; relaunching")
            once.run()
        }) == true else { return false }
        log.append("automatic relaunch held by the host until nothing would be cut off")
        heldAutomaticRelaunch = once
        setState(.installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: { [weak self] in
                self?.endAutomaticInstallHold()
                once.run()
            },
            dismiss: {}
        )))
        return true
    }

    /// Drops the host's hold on an automatic install or relaunch: a click, a cancel or the end of
    /// the update session took over.
    func endAutomaticInstallHold() {
        heldAutomaticRelaunch = nil
        quitInstall = nil
        automaticInstallItem = nil
        actionDelegate?.updaterEndsAutomaticInstallHold()
    }

    private func currentRelaunchBlockers() -> UpdateRelaunchBlockers {
        actionDelegate?.updaterRelaunchBlockers() ?? .empty
    }

    /// Holds `install` while relaunching would interrupt a busy agent or a running command.
    /// Later leaves the downloaded update on "Restart to Complete Update"; Sparkle still
    /// installs it when cmux quits.
    private func holdRelaunch(isAutoUpdate: Bool, automatic: Bool = false,
                              install: @escaping () -> Void) {
        relaunchGate.hold(
            isAutoUpdate: isAutoUpdate,
            automatic: automatic,
            blockers: { [weak self] in self?.currentRelaunchBlockers() ?? .empty },
            isShown: { [weak self] in
                guard case .installing(let installing) = self?.model.state else { return false }
                return installing.relaunchBlockers != nil
            },
            publish: { [weak self] state in self?.setState(state) },
            relaunch: install,
            later: { [weak self] in self?.showRestartToComplete(install: install) }
        )
    }

    /// The postponed Sparkle session stays open until `install` runs, so this state keeps it
    /// reachable: Restart Later only closes the popover (dropping `install` would leave every
    /// later check waiting on a session that never ends), and Restart Now goes through the
    /// gate again as a user install (the "auto" flag only labels the state) and installs at
    /// most once.
    private func showRestartToComplete(install: @escaping () -> Void) {
        let once = InstallOnce(install)
        setState(.installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: { [weak self] in
                guard let self else {
                    once.run()
                    return
                }
                guard self.holdsUserInstalls else {
                    once.run()
                    return
                }
                self.holdRelaunch(isAutoUpdate: true, install: once.run)
            },
            dismiss: {}
        )))
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        log.append("show installing update")
        setState(.installing(.init(
            retryTerminatingApplication: retryTerminatingApplication,
            dismiss: { [weak self] in
                self?.model.setState(.idle)
            }
        )))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        log.append("show update installed (relaunched=\(relaunched))")
        relaunchGate.cancel()
        endAutomaticInstallHold()
        setState(.idle)
        acknowledgement()
    }

    func showUpdateInFocus() {
        // No-op; cmux never shows Sparkle dialogs.
    }

    func dismissUpdateInstallation() {
        // This callback has no prompt/session identity. User actions update the model at their
        // causal boundary, and UpdateController reconciles unexpected active-session termination
        // from Sparkle's authoritative cycle-finished callback. Mutating here could only let an old
        // session erase a newer prompt or an accepted install (#8368).
        log.append("dismiss update installation observed (state=\(describe(model.state)); no state mutation)")
    }

    func handlePromptReply(_ reply: UpdatePromptReply,
                           choice: SPUUserUpdateChoice,
                           source: UpdatePromptReplySource,
                           item: SUAppcastItem? = nil) {
        log.append("update prompt reply consumed (choice=\(choice.rawValue), source=\(source.rawValue))")
        // Whoever answered Install (a background accept, an Install Update click that
        // confirmed a fresh check, the user), the download that follows stages this
        // item, so ``stagedItem`` always names the build this driver downloaded.
        if choice == .install, let item { backgroundItem = item }
        guard source == .user, choice == .dismiss || choice == .skip else { return }

        guard case .updateAvailable(let available) = model.state,
              available.reply.id == reply.id else {
            log.append("user prompt reply did not match live prompt; preserving current state")
            return
        }

        // Tell the lifecycle owner only after the structured prompt identity matches. A delayed
        // action from an old prompt must not cancel a newer check or accepted install.
        eventDelegate?.updateDriverUserDidDismissPrompt()
        setState(.idle)
    }

    /// Whether the check being answered is one the person started: only those enter the
    /// checking states (``showUserInitiatedUpdateCheck(cancellation:)``).
    private var isUserInitiatedCheck: Bool {
        switch model.state {
        case .checking, .preparingCheck: true
        default: false
        }
    }

    // MARK: - State transition helpers

    /// Replaces the visible state. Controller paths that supersede a check use this instead of
    /// mutating the model directly.
    func replaceActiveState(with replacement: UpdateState) {
        invalidatePreparedOffer()
        model.replaceActiveState(with: replacement)
    }

    private func beginChecking(cancel: @escaping () -> Void) {
        invalidatePreparedOffer()
        model.setOverrideState(nil)
        checkTimeoutTask?.cancel()
        checkTimeoutTask = nil
        applyState(.checking(.init(cancellationHandler: { [weak self] source in
            guard let self else {
                cancel()
                return
            }
            self.invalidatePreparedOffer()
            self.log.append("update check cancellation requested (source=\(source))")
            if source == .user {
                self.eventDelegate?.updateDriverUserDidCancelCheck()
            }
            cancel()
            if source == .user, case .checking = self.model.state {
                self.setState(.idle)
            }
        })))
        scheduleCheckTimeout()
    }

    func setState(_ newState: UpdateState) {
        invalidatePreparedOffer()
        checkTimeoutTask?.cancel()
        checkTimeoutTask = nil
        applyState(newState)
    }

    private func scheduleCheckTimeout() {
        checkTimeoutTask?.cancel()
        checkTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Bounded, cancellable check-timeout deadline via the injected clock.
            try? await self.clock.sleep(for: .seconds(self.checkTimeoutDuration))
            guard !Task.isCancelled else { return }
            guard case .checking = self.model.state else { return }
            self.setState(.notFound(.init(acknowledgement: {})))
        }
    }

    private func applyState(_ newState: UpdateState) {
        if Self.endsInstallRequest(newState) {
            installsWhenStaged = false
            relaunchIsAutomatic = false
        }
        model.applyDriverState(newState)
        log.append("state -> \(describe(newState))")
    }

    // MARK: - Feed URL tracking

    /// Returns the last feed URL reported through Sparkle, or resolves the build-time feed URL
    /// without logging or registering test URL protocols when no delegate callback has run yet.
    func resolvedFeedURLString() -> String? {
        if let lastFeedURLString {
            return lastFeedURLString
        }
        return UpdateFeedResolver().resolve(infoFeedURL: infoFeedURLProvider()).url
    }

    func recordFeedURLString(_ feedURLString: String, usedFallback: Bool) {
        if lastFeedURLString == feedURLString {
            return
        }
        lastFeedURLString = feedURLString
        let suffix = usedFallback ? " (fallback)" : ""
        log.append("feed url resolved\(suffix): \(feedURLString)")
    }

    func formatErrorForLog(_ error: any Error) -> String {
        let nsError = error as NSError
        var parts: [String] = ["\(nsError.domain)(\(nsError.code))"]
        if !nsError.localizedDescription.isEmpty {
            parts.append(nsError.localizedDescription)
        }
        if let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append("url=\(url.absoluteString)")
        } else if let urlString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            parts.append("url=\(urlString)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            let detail = "\(underlying.domain)(\(underlying.code)) \(underlying.localizedDescription)"
            parts.append("underlying=\(detail)")
        }
        if let feed = lastFeedURLString {
            parts.append("feed=\(feed)")
        }
        return parts.joined(separator: " | ")
    }

    private func describe(_ state: UpdateState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .permissionRequest:
            return "permissionRequest"
        case .preparingCheck:
            return "preparingCheck"
        case .checking:
            return "checking"
        case .updateAvailable(let update):
            return "updateAvailable(\(update.appcastItem.displayVersionString))"
        case .notFound:
            return "notFound"
        case .error(let err):
            return "error(\(err.error.localizedDescription))"
        case .startingDownload:
            return "startingDownload"
        case .downloading(let download):
            if let expected = download.expectedLength, expected > 0 {
                let percent = Double(download.progress) / Double(expected) * 100
                return String(format: "downloading(%.0f%%)", percent)
            }
            return "downloading"
        case .extracting(let extracting):
            return String(format: "extracting(%.0f%%)", extracting.progress * 100)
        case .installing(let installing):
            if let blockers = installing.relaunchBlockers {
                return "installing(auto=\(installing.isAutoUpdate), waiting agents=\(blockers.busyAgentCount) commands=\(blockers.runningCommandCount))"
            }
            return "installing(auto=\(installing.isAutoUpdate))"
        }
    }
}

/// Runs a Sparkle install handler at most once.
final class InstallOnce {
    private var install: (() -> Void)?

    init(_ install: @escaping () -> Void) {
        self.install = install
    }

    func run() {
        guard let install else { return }
        self.install = nil
        install()
    }
}
