public import CmuxUpdater
public import CmuxNextWakeups
import CmuxNextSettings
import Network
public import Foundation
import Observation

/// cmux-next's updater. Release builds (stable, NIGHTLY, RC) run the shared
/// Sparkle driver (`CmuxUpdater.UpdateController`: automatic checks from
/// the existing `SU*` defaults, launch probe, install watchdog, re-resolve
/// before install). DEV/staging builds never run Sparkle; their checks are
/// a read-only probe of the same feed.
///
/// One per process, owned by the App. Action handlers call ``checkForUpdates()``,
/// ``installAvailableUpdate()`` and ``switchChannel(to:)``. No Sparkle window opens; Sparkle's
/// user-driver steps are the sidebar's cards. Without the automatic-install opt-in
/// (`updates.downloadAutomatically`, off by default on every channel) a found update is the
/// update-found step (the notice card after Check for Updates, else the titlebar's Update
/// Available) and a downloaded one is the Update Ready card, which asks before relaunching; with
/// it, updates download by themselves and the Update Ready card still asks before the relaunch.
/// A check's progress and result show on the notice card (``card``). The update sheet
/// (``UpdateSheetModel``) opens only for a failure's details.
@MainActor
@Observable
public final class UpdaterService {
    public let identity: UpdateBuildIdentity
    /// The blocking-work lanes the kept-versions listing runs on (the app's one, AppServices; tests and
    /// previews get lanes of their own).
    let work: BackgroundWork
    public let log: UpdateLogBuffer
    /// The Sparkle driver; nil when Sparkle cannot run in this build.
    public let controller: UpdateController?
    public private(set) var lastProbe: UpdateProbeResult?
    public private(set) var lastProbeError: String?
    public private(set) var isProbing = false
    /// The running stable <-> NIGHTLY switch, if any.
    public private(set) var channelSwitchPhase: AppChannelSwitchPhase?
    public private(set) var channelSwitchError: String?
    /// `UpdateChannel` from the managed policy, or nil.
    public internal(set) var managedChannel: AppChannelSwitchTarget?
    /// `MinimumVersion` from the managed policy, or nil.
    public internal(set) var managedMinimumVersion: String?
    /// Whether the circle shows the last probe's result (the user asked, in a
    /// build without Sparkle).
    public internal(set) var showsProbeResult = false
    /// A fixed circle phase for screenshots (`debug.update_indicator`).
    public var debugIndicatorPhase: UpdateIndicatorPhase? {
        didSet { syncFlowPhase() }
    }
    /// The R114 install gate over ``indicatorPhase``.
    public internal(set) var flow = UpdateFlow()
    /// How many times the gate's phase moved (``syncFlowPhase()``): a caller that follows one
    /// request (the CLI's install) tells a phase its request reached from one already shown,
    /// even when observation coalesces the moves in between.
    public internal(set) var flowMoves = 0
    /// UPDATE-CARD-CLOSE: the update version whose card the person closed and the end of a
    /// "Remind Me Later" (``UpdateSnooze``, kept in `defaults`).
    public internal(set) var updateSnooze = UpdateSnooze()
    /// The pending reminder's end, on the injected clock (one-shot; re-armed at launch).
    @ObservationIgnored let snoozeTimer: DemandTimer
    /// The pulled-build banner (made on first use; it needs `self`).
    @ObservationIgnored public private(set) lazy var pulledWatch = PulledBuildWatch(updater: self)
    /// The app-owned per-PR kill-switch reader; retaining it cancels its observation with the updater.
    /// ``startKillSwitchReader()`` stops the one before through this property.
    @ObservationIgnored var killSwitchReader: KillSwitchReader?
    /// The notice whose timeout is pending, and its one-shot deadline on the
    /// injected clock (no `asyncAfter`).
    @ObservationIgnored var expiringCard: UpdateCard?
    @ObservationIgnored let cardTimer: DemandTimer
    /// When the install phase began (``installStatus``), nil outside it.
    @ObservationIgnored var installStartedAt: Date?
    /// Bumped by ``installTimer`` so the installing card's seconds move.
    var installTick = 0
    /// The person closed the card of an install that never relaunched.
    var installCardDismissed = false
    /// The install already gave up (``UpdateInstallStatus/Stage/stalled``) once.
    @ObservationIgnored var installGaveUp = false
    /// The installing card's one-second tick, only while an install runs.
    @ObservationIgnored let installTimer: DemandTimer
    @ObservationIgnored let stagedRefresh: StagedUpdateRefresh
    /// The tip app's 5-minute feed read while nothing waits (``TipUpdateCheck``).
    @ObservationIgnored let tipCheck: TipUpdateCheck
    /// The release push's socket (``ReleasePushListener``), run by ``refreshReleasePush()``.
    @ObservationIgnored let releasePush: ReleasePushListener
    /// The pushed build not seen through yet and the reads left for it (``releasePushed(_:)``).
    @ObservationIgnored var releasePushTarget: (build: String, reads: Int)?
    /// The next read for ``releasePushTarget`` (one-shot; cancelled when the push stops).
    @ObservationIgnored var releasePushRetry: DemandTimer
    /// Opens the changelog page (set by the App; the What's New page's link).
    @ObservationIgnored public var openChangelog: (() -> Bool)?
    /// Opens the changelog page for the releases after `from` up to `to`
    /// (set by the App).
    @ObservationIgnored public var openChangelogSpan: ((_ from: String, _ to: String) -> Bool)?
    /// Opens a web release notes page in a browser tab (set by the App;
    /// "See all changes" when the staged build has no signed notes).
    @ObservationIgnored public var openReleaseNotesURL: ((URL) -> Bool)?
    /// Runs an allow-listed action id (set by the App; an announcement's Try It).
    @ObservationIgnored public var runAllowListedAction: ((String) -> Void)?
    /// The announcement cards to show (filtered), newest feed order.
    public internal(set) var announcements: [Announcement] = []
    /// `announcements.enabled` / `announcements.fetch` (set by the App).
    public var announcementsEnabled = true { didSet { if oldValue != announcementsEnabled { refreshAnnouncements() } } }
    public var announcementsFetch = true
    @ObservationIgnored var announcementsLoader: (@Sendable () async -> [Announcement])?
    @ObservationIgnored var allAnnouncements: [Announcement] = []
    /// What's New after an update (WHATS-NEW-AFTER-UPDATE): the bundled
    /// documents and this feed's nightly digests. The App loads it at launch.
    public let whatsNew: WhatsNewCenter
    /// Where a staged update is recorded for the next build's What's New
    /// (nil: not recorded).
    @ObservationIgnored let lastUpdates: WhatsNewLastUpdateStore?
    /// The record last written, so an unchanged one is not written again.
    @ObservationIgnored var recordedUpdate: WhatsNewLastUpdate?
    /// The running bundle's keep for rollback (``keepRunningBuildForRollback()``).
    @ObservationIgnored var keptRunningBuild: KeepState?
    @ObservationIgnored var keepTask: Task<Void, Never>?
    /// Takes the windows off the screen as Sparkle commits to a relaunch the
    /// person asked for (set by the App: ``UpdateWindowHandoff/hide()``), not
    /// at the click. ``installAbandoned`` undoes it when the install ends
    /// without a relaunch.
    @ObservationIgnored public var hidesForRelaunch: (() -> Void)?
    @ObservationIgnored public var installAbandoned: (() -> Void)?
    /// Reads a build's verified notes (``releaseNotes`` in the app; replaced by tests).
    @ObservationIgnored var notesLoader: (@Sendable (String) async -> ReleaseNotes?)?
    /// UPDATE-CARD: the staged update's display version (kept while it
    /// installs) and its verified notes, fetched once when it was staged.
    public internal(set) var stagedVersion: String?
    public internal(set) var stagedNotes: ReleaseNotes?
    @ObservationIgnored var stagedNotesTask: (build: String, task: Task<Void, Never>)?
    /// This build's own verified notes, read once when the Updated card has
    /// no change list of its record (``loadCurrentBuildNotesIfNeeded()``).
    public internal(set) var currentBuildNotes: ReleaseNotes?
    @ObservationIgnored var currentBuildNotesTask: Task<Void, Never>?
    /// The staged appcast item's build (replaced by tests).
    @ObservationIgnored var stagedBuild: () -> String? = { nil }
    /// `updates.downloadAutomatically` (the card's Automatic Updates box).
    public internal(set) var automaticUpdates = true
    /// Writes a setting the updater's cards change (set by the App).
    @ObservationIgnored public var writeSetting: ((UpdaterSetting, Bool) -> Void)?
    /// BOTTOM-LEFT-CARDS K1: today's "Did you know" tip (nil: none, or
    /// `sidebar.cards.tips` off) and what the tips remember on this Mac.
    public internal(set) var tip: Tip?
    @ObservationIgnored var tipState = TipState()
    /// `sidebar.cards.tips` (set by the App once settings load; nil before,
    /// and no tip shows until then); turning it on again ends a timed mute.
    public var tipsEnabled: Bool? {
        didSet {
            guard oldValue != tipsEnabled else { return }
            if oldValue == false, tipsEnabled == true { tipsTurnedOn() }
            refreshTip()
        }
    }
    /// Runs a tip's action as the user's own (set by the App: the registry).
    @ObservationIgnored public var runTipAction: ((String) -> Void)?
    /// Re-picks the tip when the app becomes active (``refreshTipOnActivation()``).
    @ObservationIgnored var activationObservation: Task<Void, Never>?
    /// The test feed in use ("Use Test Update Feed"), or nil.
    public internal(set) var testFeedURL: String?
    /// The release ring followed in the cmux-next appcast (`updates.channel`, ``follow(ring:)``).
    public internal(set) var ring: UpdateRing = .nightly
    /// The App applied `updates.channel` once (launch); a later move is the person's pick and checks at once.
    @ObservationIgnored var ringFollowed = false
    /// The `updates.*` settings the gate reads (set by the App).
    public var preferences = UpdatePreferences.defaults
    /// Sparkle's staged install and its cancel (replaced by tests).
    @ObservationIgnored var installStaged: () -> Void = {}
    /// The install click replaced a stale staged build (``StagedUpdateRefresh/beforeInstall(updater:install:)``):
    /// the click carries over to the newer build's check and download (``carryInstallClick(_:)``).
    @ObservationIgnored var installAfterSwap = false
    /// Why the newest build downloads in place of a stale or pulled one, or nil (``followNewestFetch(_:previous:)``).
    var newestFetch: NewestFetch?
    /// Pulled staged builds already dropped once (``followPulled()``).
    @ObservationIgnored var droppedPulled: Set<String> = []
    /// The running build's pull started its fetch of the newest build (once per launch).
    @ObservationIgnored var runningPulledHandled = false
    /// Replaces the install click's disk preflight (``installPreflightFailure()``) in tests.
    @ObservationIgnored var preflightOverride: (() -> UpdateInstallPreflight.Failure?)?
    /// The cancel returns whether an installer was held and is now cancelled.
    @ObservationIgnored var cancelStaged: () -> Bool = { false }
    @ObservationIgnored var acceptAvailable: () -> Void = {}
    /// Stops Sparkle's running download (its cancellation deletes the partial file); returns
    /// whether a download was running. Replaced by tests.
    @ObservationIgnored var cancelDownloadNow: () -> Bool = { false }
    /// The download the person cancelled: the card shows its found update again until another
    /// check or download starts (``cancelDownloadClicked()``).
    var cancelledDownload: CancelledDownload?
    /// The Update click on a cancelled download's card started a check: the update it finds
    /// downloads (``followCancelledDownload(_:)``).
    @ObservationIgnored var downloadAfterCheck = false
    /// The phase ``followCancelledDownload(_:)`` saw last.
    @ObservationIgnored var lastCancelFollowed: UpdateIndicatorPhase = .hidden
    @ObservationIgnored var phaseObservation: Task<Void, Never>?
    @ObservationIgnored var pathMonitor: NWPathMonitor?
    @ObservationIgnored var network: (constrained: Bool, expensive: Bool) = (false, false)
    /// `updates.downloadAutomatically` and `meteredNetwork` as last configured; nothing downloads
    /// by itself until the settings load (``configure``).
    @ObservationIgnored var downloadSetting: (enabled: Bool, metered: UpdateMeteredMode) = (false, .deferLowData)
    /// ``configure`` applied the `updates.*` settings once: before that the fast check and the
    /// release push read nothing (`updates.checkAutomatically` may be off).
    @ObservationIgnored var settingsApplied = false
    /// The found update waiting on the update-found step: its build, and the dismiss that ends its
    /// Sparkle prompt without skipping it (a newer build replaces it, ``TipUpdateCheck``). Replaced by tests.
    @ObservationIgnored var availableBuild: () -> String? = { nil }
    @ObservationIgnored var dismissAvailable: () -> Void = {}
    /// Whether found updates download by themselves now (``applyDownloadPolicy()``).
    @ObservationIgnored var downloadsFoundUpdates = false
    /// The App's observation of the `updates.*` settings.
    @ObservationIgnored public var settingsObservation: Task<Void, Never>?
    @ObservationIgnored let now: () -> Date
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The card kind last written to the update harness's timeline.
    @ObservationIgnored var markedCardKind: String?
    #endif

    /// Asks the App to show the update sheet (set by the App): a failure's details only.
    @ObservationIgnored public var presentUpdateUI: (() -> Void)?
    /// Sparkle is about to relaunch into the update (set by the App: the quit keeps every terminal).
    @ObservationIgnored public var willRelaunch: (() -> Void)?
    /// Quits and reopens the app behind once it exits (``UpdateRelaunchBehind``): the first closure
    /// runs just before the quit (false: the user came into the app, so no quit), the second when
    /// the app did not quit, the third when the first said no. Nil (tests, hosts without it) lets
    /// Sparkle relaunch.
    @ObservationIgnored public var relaunchBehind: ((_ willQuit: @escaping @MainActor () async -> Bool, _ declined: @escaping @MainActor () -> Void,
                                                     _ inFront: @escaping @MainActor () -> Void) -> Void)?
    /// Reads the executable's live session and input state before Sparkle relaunches.
    @ObservationIgnored public var relaunchBlockers: () -> UpdateRelaunchBlockers = { .daemonUnavailable }
    /// Holds an automatic install while a modal, sheet, menu or composition is up (``UpdateRelaunchMoment``).
    @ObservationIgnored let relaunchMomentHold: UpdateRelaunchMomentHold
    /// How long input must be quiet before a nightly installs by itself (`updates.idleInstallQuietSeconds`).
    @ObservationIgnored public internal(set) var idleInstallQuiet: Duration = UpdateRelaunchBlockers.quietInputPeriod
    /// The install in flight started by itself (the idle policy): a failure opens nothing.
    @ObservationIgnored var automaticInstallInFlight = false
    /// The build Sparkle said it installs (`updaterWillInstallUpdate`): the relaunch's focus record names it.
    @ObservationIgnored var installingBuild: String?
    /// The build whose install left this build running at the last relaunch, and why
    /// (``UpdateInstallCheck``); the staged update card says so while that build is staged.
    public internal(set) var failedInstall: (build: String, failure: UpdateInstallFailure)?
    /// The frontmost app when the automatic install in flight started (``UpdateRelaunchFocus``).
    @ObservationIgnored var automaticInstallFrontmost: UpdateFrontmostApp?
    /// Whether this app is the frontmost one, and the app that is (``UpdateRelaunchFocus``); AppKit in
    /// the app, a fake in tests.
    @ObservationIgnored public var frontmost: () -> UpdateFrontmostApp = { UpdateFrontmostApp.current() }
    /// Whether a window shows the update notice (the sidebar footer's
    /// pill). Without it, checks and installs open the update sheet.
    @ObservationIgnored public var showsIndicator: () -> Bool = { true }
    /// Whether the update sheet is on screen (set by the App): a note's
    /// timeout then leaves the state alone so the sheet keeps its details.
    @ObservationIgnored public var isSheetPresented: () -> Bool = { false }
    @ObservationIgnored let policy: ManagedUpdatePolicy
    @ObservationIgnored let prober: UpdateProber
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let switcher: AppChannelSwitcher
    @ObservationIgnored private var probeTask: Task<String?, Never>?
    @ObservationIgnored private var switchTask: Task<String?, Never>?
    @ObservationIgnored private var started = false
    /// A check the person asked for runs in Sparkle (cleared when the flow leaves checking).
    @ObservationIgnored var userCheckRunning = false
    /// Whether ``start()`` ran (the managed policy checks only after it).
    var isStarted: Bool { started }

    /// - Parameter enableSparkle: false builds no Sparkle driver even for a
    ///   release identity (tests, demos).
    /// - Parameter recordsUpdates: false neither writes nor reads the update
    ///   record What's New shows after an update (tests, demos).
    public init(identity: UpdateBuildIdentity = .main(),
                policy: ManagedUpdatePolicy = .live(),
                prober: UpdateProber = UpdateProber(),
                defaults: UserDefaults = .standard,
                switcher: AppChannelSwitcher = AppChannelSwitcher(),
                enableSparkle: Bool = true,
                recordsUpdates: Bool = true,
                now: @escaping () -> Date = Date.init,
                clock: any Clock<Duration> = ContinuousClock(),
                work: BackgroundWork = BackgroundWork(label: "com.cmuxterm.next.work.updater")) {
        self.now = now
        self.work = work
        automaticUpdates = identity.track.downloadsAutomaticallyByDefault
        cardTimer = DemandTimer(owner: "UpdaterService.card", clock: clock)
        installTimer = DemandTimer(owner: "UpdaterService.install", clock: clock)
        snoozeTimer = DemandTimer(owner: "UpdaterService.snooze", clock: clock)
        stagedRefresh = StagedUpdateRefresh(clock: clock)
        tipCheck = TipUpdateCheck(clock: clock)
        releasePushRetry = DemandTimer(owner: "UpdaterService.releasePush", clock: clock)
        self.identity = identity
        self.policy = policy
        self.prober = prober
        self.defaults = defaults
        self.switcher = switcher
        let lastUpdates = recordsUpdates ? WhatsNewLastUpdateStore.app(bundleIdentifier: identity.bundleIdentifier) : nil
        self.lastUpdates = lastUpdates
        whatsNew = WhatsNewCenter(currentVersion: identity.shortVersion, currentBuild: identity.build, defaults: defaults,
                                  sources: Self.whatsNewSources(identity: identity), lastUpdates: lastUpdates)
        let log = UpdateLogBuffer()
        self.log = log
        relaunchMomentHold = UpdateRelaunchMomentHold(clock: clock, log: { [log] in log.append($0) })
        releasePush = ReleasePushListener(runningBuild: identity.build, clock: clock, log: { [log] in log.append($0) })
        // The managed policy is re-read by the driver on every start and check,
        // so it is not a reason to skip building it.
        if enableSparkle, identity.sparkleDisabledReason(managedPolicyDisablesUpdates: false) == nil {
            // The track decides, not the bundle id: the tip app has a DEV id but runs Sparkle.
            let controller = UpdateController(log: log, defaults: defaults, isDevLikeBundle: identity.track == .development,
                                              isDisabledByPolicy: { policy.disablesUpdates })
            // No Sparkle window: the found and staged steps are the sidebar's cards.
            // Set on this updater only; no defaults change, so the legacy app
            // sharing the domain keeps its own behavior.
            controller.installsUpdatesInBackground = true
            // The daemon keeps every terminal, agent and running turn, so all app relaunches are
            // immediate. `UpdateDriver` uses this same flag for automatic installs.
            controller.holdsUserInstalls = false
            // A found update is offered at once, deltas listed or not: no check holds a build back
            // for deltas that come minutes later (a later check uses them for the next build).
            // Until the settings load (``configure``), a launch check's update waits: nothing
            // downloads or installs by itself, whichever way `updates.downloadAutomatically` is set.
            // Once it is on, a downloaded update installs by itself once staged; the daemon preserves
            // agents, commands and turns while the app relaunches.
            controller.installsUpdatesWhenIdle = false
            controller.downloadsUpdatesInBackground = false
            self.controller = controller
        } else {
            #if DEBUG || CMUX_BENCH_HOOKS
            controller = enableSparkle ? UpdateHarness.current?.controller(identity: identity, log: log, defaults: defaults, policy: policy) : nil
            #else
            controller = nil
            #endif
        }
        if let controller {
            installStaged = { [weak controller] in controller?.installStagedUpdate() }
            cancelStaged = { [weak controller] in controller?.cancelStagedUpdate() ?? false }
            acceptAvailable = { [weak controller] in controller?.acceptAvailableUpdate() }
            cancelDownloadNow = { [weak controller] in
                guard case .downloading(let download)? = controller?.model.state else { return false }
                download.cancel()
                return true
            }
            stagedBuild = { [weak controller] in controller?.stagedUpdate?.versionString }
            availableBuild = { [weak controller] in
                guard case .updateAvailable(let available)? = controller?.model.state else { return nil }
                return available.appcastItem.versionString
            }
            dismissAvailable = { [weak controller] in
                guard case .updateAvailable(let available)? = controller?.model.state, !available.reply.isConsumed else { return }
                available.reply(.dismiss)
            }
        }
        restorePinnedTestFeed()
        restoreRollbackSkip()
        checkLastInstall()
        releasePush.onNewerBuild = { [weak self] in self?.releasePushed($0) }
        tipState = TipState(defaults: defaults)
        // The app settled the install before making the updater (AppServices): an install that ran
        // before tips counts as having used the catalog's basics.
        storeTipState(TipChooser.settleInstall(tipState, catalog: TipCatalog.all, install: tipBudget.install))
        updateSnooze = UpdateSnooze(defaults: defaults)
    }

    /// Makes this updater's kill-switch reader and follows it; the reader started before stops.
    func startKillSwitchReader() {
        killSwitchReader?.stop()
        let reader = KillSwitchReader(updater: self)
        killSwitchReader = reader
        reader.follow()
    }

    /// Why Sparkle does not run right now, or nil.
    public var disabledReason: UpdateDisabledReason? {
        if controller == nil, let reason = identity.sparkleDisabledReason(managedPolicyDisablesUpdates: policy.disablesUpdates) {
            return reason
        }
        return policy.disablesUpdates ? .managedPolicy : nil
    }

    /// Starts Sparkle (its checks honor `SUEnableAutomaticChecks`). Idempotent; no-op without a driver.
    public func start() {
        guard !started else { return }
        started = true
        if presentUpdateUI != nil { startKillSwitchReader() }
        observeFlowPhase()
        refreshAnnouncements()
        refreshTip()
        refreshUpdateSnooze()
        tipCheck.refresh(self)
        refreshReleasePush()
        pulledWatch.onRefresh = { [weak self] in self?.followPulled() }
        guard let controller else {
            log.append("sparkle not started (\(disabledReason?.rawValue ?? "no driver"), track=\(identity.track.rawValue))")
            return
        }
        controller.actionDelegate = self
        // A found build known pulled never downloads, even when downloads are automatic.
        controller.refusesUpdate = { [weak self] in self?.isKnownPulled($0) ?? false }
        controller.prepareUpdate = { [weak self] in
            guard let self else { return }
            await self.pulledWatch.refresh().value
        }
        let pulledListReady = pulledWatch.start(controller: controller)
        // Do not let Sparkle's launch/background check race the pulled-build list. Until that
        // read completes, a pulled appcast item is not yet known to ``refusesUpdate`` and could
        // be accepted and downloaded before ``followPulled()`` gets a chance to cancel it.
        Task { @MainActor [weak self, weak controller] in
            await pulledListReady.value
            guard let self, let controller, self.started else { return }
            controller.startUpdaterIfNeeded()
            #if DEBUG || CMUX_BENCH_HOOKS
            if UpdateHarness.current?.backgroundCheck == true {
                UpdateHarness.mark("background_check")
                controller.checkInBackground()
            }
            #endif
            self.recheckRequiredUpdate()
        }
    }

    /// The user asked to check. With Sparkle it starts a foreground Sparkle
    /// check (a found update downloads, no sheet), else a read-only probe
    /// whose result the circle notes (never under a managed policy, which
    /// forbids touching the feed). The returned task finishes when a probe
    /// has its result (nil) or failed (the reason).
    ///
    /// The answer is on screen before this returns (Lawrence 2026-10-19: "I
    /// can't tell if it's being checked for right now"): the gate takes the
    /// new phase here, not one observation hop later, so the notice card
    /// shows "Checking for Updates…" in the next frame. A request while the
    /// person's check runs joins it: the same progress shows and nothing new
    /// is fetched.
    @discardableResult
    public func checkForUpdates() -> Task<String?, Never>? {
        if needsSheet { presentUpdateUI?() }
        // The person asked: a closed or snoozed update card shows again.
        clearUpdateSnooze()
        send(.checkRequested)
        defer { syncFlowPhase() }
        switch disabledReason {
        case .managedPolicy:
            log.append("check suppressed (managed policy)")
            return nil
        case nil:
            syncFlowPhase()
            if case .ready = flow.phase {
                // Sparkle ignores a check while an update waits: the card answers, and a newer ring build replaces it.
                log.append("check while an update waits: showing the staged update")
                if stagedRefresh.run(reason: "check", updater: self) == nil { flow.askAnswered() }
                return nil
            }
            guard let controller else { return nil }
            if userCheckRunning, case .checking = flow.phase {
                // Sparkle would queue a second check after this one, which only delays the answer.
                log.append("check while the person's check runs: joined")
                return nil
            }
            controller.model.setOverrideState(nil)
            controller.checkForUpdates()
            userCheckRunning = true
            return nil
        case .developmentBuild, .missingPublicKey:
            showsProbeResult = true
            return probe()
        }
    }

    /// Reads the feed and records what it offers this Mac. Joins a probe
    /// already in flight.
    @discardableResult
    public func probe() -> Task<String?, Never> {
        if let probeTask { return probeTask }
        isProbing = true
        let prober = prober
        // Sparkle's allowedChannels reads the baked feed, not a test feed: the probe does the same.
        let allowed = identity.feed().channel.allowedSparkleChannels(ring: ring)
        var identity = identity
        if let testFeedURL { identity.infoFeedURL = testFeedURL }
        let task = Task { [weak self] () -> String? in
            let failure: String?
            do {
                let result = try await prober.probe(identity, allowedChannels: allowed)
                self?.lastProbe = result
                self?.lastProbeError = nil
                self?.log.append("probe \(result.outcome.kind) feed=\(result.feedURL) items=\(result.itemCount)")
                failure = nil
            } catch {
                let reason = String(describing: error)
                self?.lastProbeError = reason
                self?.log.append("probe failed: \(reason)")
                failure = reason
            }
            self?.isProbing = false
            self?.probeTask = nil
            return failure
        }
        probeTask = task
        return task
    }

    /// Installs and relaunches the downloaded update at once, or the one
    /// being checked for or downloaded as soon as it is staged. With
    /// nothing found yet, it runs a fresh check (the shared driver's attempt
    /// flow, so never a stale version) whose progress and result show on the
    /// notice card; a found update downloads and waits as the staged update
    /// card (Restart to Update).
    public func installAvailableUpdate() throws {
        guard let controller, disabledReason == nil else { throw UpdaterUnavailable(reason: disabledReason) }
        #if DEBUG || CMUX_BENCH_HOOKS
        UpdateHarness.mark("install_clicked")
        #endif
        if needsSheet { presentUpdateUI?() }
        clearUpdateSnooze()
        controller.model.setOverrideState(nil)
        syncFlowPhase()
        // As for a check: the loading card shows in the next frame, not one observation hop later.
        defer { syncFlowPhase() }
        switch flow.phase {
        case .ready, .available, .downloading, .checking:
            // The gate installs once the update is staged and no agent is busy.
            send(.installRequested)
        case .hidden, .installing, .note:
            // Nothing found yet: an explicit install runs Sparkle's attempt
            // flow (a fresh check that installs the newest at once). The
            // user asked, so its progress and result show on the notice
            // card (up to date, downloading, the failure), as for a check.
            send(.checkRequested)
            controller.attemptUpdate()
        }
    }

    /// Opens the other release app (stable <-> NIGHTLY), downloading,
    /// verifying and installing it first when missing. Both apps coexist.
    @discardableResult
    public func switchChannel(to target: AppChannelSwitchTarget) throws -> Task<String?, Never> {
        guard identity.channelSwitchTarget == target else { throw UpdaterUnavailable.cannotSwitch(to: target, from: identity.track) }
        if policy.disablesUpdates { throw UpdaterUnavailable(reason: .managedPolicy) }
        if let refusal = managedChannelRefusal(target) { throw refusal }
        if let switchTask { return switchTask }
        channelSwitchError = nil
        let switcher = switcher
        let task = Task { [weak self] () -> String? in
            // The switcher reports phases from its own threads. They reach the main actor through
            // one ordered stream (state-audit U1): the newest phase is applied, in order, before the
            // switch ends, and a phase reported after the end (a late progress callback) is dropped.
            let (phases, sink) = AsyncStream.makeStream(of: AppChannelSwitchPhase.self, bufferingPolicy: .bufferingNewest(1))
            // task-owner: the switch task; ends when the switch finishes the stream below
            let applier = Task { @MainActor [weak self] in
                for await phase in phases { self?.channelSwitchPhase = phase }
            }
            var failure: String?
            do {
                let outcome = try await switcher.switchTo(target) { phase in sink.yield(phase) }
                self?.log.append("channel switch to \(target.rawValue): \(outcome)")
            } catch {
                failure = String(describing: error)
                self?.channelSwitchError = failure
                self?.log.append("channel switch to \(target.rawValue) failed: \(failure ?? "")")
            }
            sink.finish()
            await applier.value
            self?.channelSwitchPhase = nil
            self?.switchTask = nil
            return failure
        }
        switchTask = task
        return task
    }

    public var status: UpdaterStatus {
        let reason = disabledReason
        let state = controller?.model.effectiveState ?? .idle
        return UpdaterStatus(
            track: identity.track,
            bundleIdentifier: identity.bundleIdentifier,
            version: identity.shortVersion,
            build: identity.build,
            minimumSystemVersion: identity.minimumSystemVersion,
            system: .current,
            feedURL: testFeedURL ?? identity.feed().url,
            sparkleDisabledReason: reason,
            automaticChecks: reason == nil && bool(UpdateSettings.automaticChecksKey, fallback: true),
            // cmux NEXT's own `updates.downloadAutomatically` as applied (network and managed policy
            // included), not Sparkle's `SUAutomaticallyUpdate`: cmux NEXT stages through its own driver
            // and turns that key off at every launch, and the legacy NIGHTLY app shares it.
            automaticDownloads: reason == nil && downloadsFoundUpdates,
            phase: UpdatePhase(state),
            detectedVersion: controller?.model.detectedUpdateVersion,
            probing: isProbing,
            lastProbe: lastProbe,
            lastProbeError: lastProbeError,
            channelSwitchTarget: identity.channelSwitchTarget,
            testFeedURL: testFeedURL,
            ring: ring,
            card: card,
            cardPresentation: cardPresentation,
            badge: footerPill?.title
        )
    }

    private func bool(_ key: String, fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? (Bundle.main.object(forInfoDictionaryKey: key) as? Bool) ?? fallback
    }
}

extension UpdaterService {
    /// ``switchChannel(to:)`` by name (`stable`, `nightly`); nil means the
    /// counterpart of the running app.
    @discardableResult
    public func switchChannel(named name: String?) throws -> Task<String?, Never> {
        let requested = name.flatMap { AppChannelSwitchTarget(rawValue: $0.lowercased()) }
        guard let target = requested ?? identity.channelSwitchTarget, name == nil || requested != nil else {
            throw UpdaterUnavailable.cannotSwitch(to: name ?? "?", from: identity.track)
        }
        return try switchChannel(to: target)
    }

    /// Why switching channels is impossible here (DEV/RC builds have no
    /// counterpart), or nil.
    public var channelSwitchUnavailableReason: String? {
        guard let target = identity.channelSwitchTarget else {
            return UpdaterUnavailable.cannotSwitch(to: "stable/nightly", from: identity.track).description
        }
        return managedChannelRefusal(target)?.description
    }

    /// Why installing is impossible here, or nil.
    public var installUnavailableReason: String? {
        controller != nil && disabledReason == nil ? nil : UpdaterUnavailable(reason: disabledReason).description
    }
}
