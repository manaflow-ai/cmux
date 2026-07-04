public import Foundation
@preconcurrency import Sparkle

/// Coordinates cmux's custom Sparkle update flow: owns the `SPUUpdater` and its
/// ``UpdateDriver``, exposes the observable ``UpdateStateModel``, and sequences the
/// user-facing actions (check, attempt-and-install).
///
/// The previous implementation observed the model's `@Published` state through Combine
/// (`$state.sink`, `Publishers.CombineLatest`). This version consumes the model's
/// ``UpdateStateModel/stateChanges()`` `AsyncStream` in one long-lived main-actor task and
/// runs its reactions (attempt-update via ``AttemptUpdateCoordinator``, "no updates"
/// auto-dismiss) as plain state-machine logic. Bounded delays (and the updater-readiness wait)
/// use the injected ``UpdateClock``.
///
/// Construct one at app startup, set ``actionDelegate``, and inject it where the update menu
/// items and pill live. This is the package's composition surface; the app target supplies the
/// concrete ``UpdateLogging`` and ``UpdateActionDelegate``.
@MainActor
public final class UpdateController {
    let updater: SPUUpdater
    let driver: UpdateDriver
    let log: any UpdateLogging
    let clock: any UpdateClock
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let hostBundle: Bundle
    private let backgroundProbeInterval: TimeInterval
    /// Whether the running build is a cmux DEV/staging build that must never be compared against
    /// the public release appcast. See ``isDevLikeBundleIdentifier(_:)``.
    let isDevLikeBundle: Bool

    /// Host actions the updater delegates upward (retry, relaunch prep). Forwarded to the driver.
    public weak var actionDelegate: (any UpdateActionDelegate)? {
        didSet { driver.actionDelegate = actionDelegate }
    }

    // Reaction state (replaces the Combine subscriptions).
    /// Sequences "re-resolve to the latest, then install" so the install path never installs the
    /// version that was captured when the prompt was first surfaced (issue #6366).
    private var attemptCoordinator = AttemptUpdateCoordinator()
    private var stateReactionTask: Task<Void, Never>?
    private var noUpdateDismissTask: Task<Void, Never>?
    private var backgroundProbeTask: Task<Void, Never>?
    private var recheckTask: Task<Void, Never>?
    // One-click auto-update state (internal, not private: the flows that use it live in
    // UpdateController+OneClick.swift).
    var silentDownloadKickTask: Task<Void, Never>?
    /// Set when a background probe finds an update mid-session; consumed when Sparkle reports
    /// the session finished (`onUpdateSessionFinished`), which is when the silent download can
    /// actually start.
    var pendingSilentDownloadKick = false
    /// The version the silent-download kick already ran for. The kicked session's own
    /// `didFindValidUpdate` re-reports the same version; without this the kick would re-arm on
    /// every failed download and hammer the feed in a loop.
    var silentDownloadKickedVersion: String?
    var backgroundRetryTask: Task<Void, Never>?
    var restartWhenIdleTask: Task<Void, Never>?
    var toastMuteExpiryTask: Task<Void, Never>?
    /// How many silent-download retries were scheduled after transient background failures;
    /// bounded so a persistent outage falls back to Sparkle's scheduled hourly check.
    var backgroundRetryCount = 0
    let backgroundRetryLimit = 3
    let backgroundRetryDelay: Duration = .seconds(5 * 60)
    /// How often the deferred "restart when idle" loop re-evaluates the host's idle signal.
    let restartWhenIdlePollInterval: Duration = .seconds(30)
    // Readiness retry. Sparkle's `canCheckForUpdates` exposes no push signal usable under
    // Swift 6 strict concurrency (KVO on the @MainActor `SPUUpdater` "sends" a non-Sendable
    // value into the change handler, and `addObserver(_:forKeyPath:)` is forbidden), so
    // readiness is awaited with a bounded retry on the injected clock — behavior-identical to
    // the original 0.25s x 20 poll, cancellable, and testable with a fake clock.
    private var readyCheckTask: Task<Void, Never>?
    private let readyRetryDelay: Duration = .milliseconds(250)
    private let readyRetryCount = 20

    private var didStartUpdater = false

    /// The observable model the UI renders from.
    public var model: UpdateStateModel { driver.model }

    /// Creates a controller, applying the Sparkle preference defaults and wiring the updater.
    ///
    /// - Parameters:
    ///   - log: The update log sink (the app's `UpdateLogStore`).
    ///   - clock: Clock for bounded UI delays. Defaults to ``SystemUpdateClock``.
    ///   - settings: The Sparkle defaults/migration configuration. Defaults to cmux's hourly check.
    ///   - hostBundle: The bundle Sparkle reads its configuration and version from.
    ///   - defaults: The `UserDefaults` the settings are applied to.
    ///   - fileManager: Filesystem access for the Sparkle installation-cache workaround;
    ///     injectable so tests can avoid touching the real filesystem.
    ///   - isDevLikeBundle: Overrides whether this is a DEV/staging build. Defaults to `nil`,
    ///     which derives it from `hostBundle.bundleIdentifier` via ``isDevLikeBundleIdentifier(_:)``.
    ///     Injectable because a `Bundle` with an arbitrary identifier cannot be constructed in tests.
    public init(log: any UpdateLogging,
                clock: any UpdateClock = SystemUpdateClock(),
                settings: UpdateSettings = UpdateSettings(),
                hostBundle: Bundle = .main,
                defaults: UserDefaults = .standard,
                fileManager: FileManager = .default,
                isDevLikeBundle: Bool? = nil) {
        self.log = log
        self.clock = clock
        self.defaults = defaults
        self.fileManager = fileManager
        self.hostBundle = hostBundle
        self.backgroundProbeInterval = settings.scheduledCheckInterval
        let isDevLikeBundle = isDevLikeBundle ?? Self.isDevLikeBundleIdentifier(hostBundle.bundleIdentifier)
        self.isDevLikeBundle = isDevLikeBundle
        settings.apply(to: defaults)
        if isDevLikeBundle {
            // DEV (`com.cmuxterm.app.debug[.<tag>]`) and staging (`com.cmuxterm.app.staging[.<tag>]`)
            // builds are produced from local source and are not on the public release train, so
            // they must never query the public appcast. Turning off Sparkle's automatic checks
            // stops the passive vectors: Sparkle never schedules its own background checks, and
            // cmux's launch/background probe is short-circuited by the `automaticallyChecksForUpdates`
            // guard in `startLaunchUpdateProbeIfNeeded`. Manual "Check for Updates" is gated
            // separately in `checkForUpdatesWhenReady`.
            defaults.set(false, forKey: UpdateSettings.automaticChecksKey)
        }

        let model = UpdateStateModel(defaults: defaults)
        let driver = UpdateDriver(model: model, log: log, clock: clock, isDevLikeBundle: isDevLikeBundle)
        self.driver = driver
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: driver,
            delegate: driver
        )
        driver.onBackgroundUpdateDetected = { [weak self] in
            guard let self else { return }
            guard let version = self.model.detectedUpdateVersion,
                  version != self.silentDownloadKickedVersion else { return }
            self.pendingSilentDownloadKick = true
            self.backgroundRetryCount = 0
        }
        driver.onUpdateSessionFinished = { [weak self] in
            self?.startSilentDownloadIfKickPending()
        }
        driver.onBackgroundSessionError = { [weak self] error in
            self?.scheduleBackgroundRetryIfTransient(error)
        }
        startStateReactions()
    }

    deinit {
        stateReactionTask?.cancel()
        noUpdateDismissTask?.cancel()
        backgroundProbeTask?.cancel()
        readyCheckTask?.cancel()
        recheckTask?.cancel()
        silentDownloadKickTask?.cancel()
        backgroundRetryTask?.cancel(); restartWhenIdleTask?.cancel(); toastMuteExpiryTask?.cancel()
    }

    // MARK: - Reaction stream

    private func startStateReactions() {
        let changes = model.stateChanges()
        stateReactionTask = Task { @MainActor [weak self] in
            self?.handleStateChange()
            for await _ in changes {
                guard let self else { return }
                self.handleStateChange()
            }
        }
    }

    /// Runs the three state reactions for the current model state. Invoked once on start and on
    /// every ``UpdateStateModel/stateChanges()`` emission (the merge of the old `$state.sink`,
    /// the attempt sink, and the `CombineLatest` dismiss observer).
    private func handleStateChange() {
        let state = model.state
        let overrideState = model.overrideState

        if attemptCoordinator.isMonitoring {
            performAttemptAction(attemptCoordinator.handleStateChange(state))
        }
        scheduleToastMuteExpiryIfNeeded()
        scheduleNoUpdateDismiss(for: state, overrideState: overrideState)
        if state.isIdle, overrideState == nil {
            startSilentDownloadIfKickPending()
        }

        if case .installing = state {
            backgroundRetryTask?.cancel(); backgroundRetryTask = nil; backgroundRetryCount = 0
            if restartWhenIdleTask != nil, !model.isRestartWhenIdleArmed { cancelRestartWhenIdleLoop() }
        } else if restartWhenIdleTask != nil {
            cancelRestartWhenIdleLoop()
        }
    }

    // MARK: - Attempt update

    /// Re-check for updates and auto-confirm the install of whatever the fresh check resolves.
    ///
    /// This is the single user-facing "install the update" entry point. It deliberately runs a
    /// fresh check instead of installing the update that was captured when the prompt was first
    /// surfaced, so a newer release published in the meantime is installed directly rather than
    /// prompting the user again right after relaunch (issue #6366).
    public func attemptUpdate() {
        performAttemptAction(attemptCoordinator.requestInstallLatest(currentState: model.state))
    }

    private func performAttemptAction(_ action: AttemptUpdateCoordinator.Action) {
        switch action {
        case .none:
            break
        case .startFreshCheck:
            checkForUpdates()
        case .confirmInstall:
            log.append("attemptUpdate installing freshly resolved update")
            model.state.confirm()
        }
    }

    // MARK: - "No updates" auto-dismiss

    private func scheduleNoUpdateDismiss(for state: UpdateState, overrideState: UpdateState?) {
        noUpdateDismissTask?.cancel()
        noUpdateDismissTask = nil

        guard overrideState == nil else { return }
        guard case .notFound(let notFound) = state else { return }

        recordUITestTimestamp(key: "noUpdateShownAt")
        noUpdateDismissTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Bounded, cancellable auto-dismiss delay via the injected clock.
            try? await self.clock.sleep(for: .seconds(UpdateTiming.noUpdateDisplayDuration))
            guard !Task.isCancelled else { return }
            guard self.model.overrideState == nil, case .notFound = self.model.state else { return }
            self.recordUITestTimestamp(key: "noUpdateHiddenAt")
            self.model.setState(.idle)
            notFound.acknowledgement()
        }
    }

    // MARK: - Checking

    /// Check for updates (used by the menu item).
    public func checkForUpdates() {
        log.append("checkForUpdates invoked (state=\(model.state.isIdle ? "idle" : "busy"))")
        checkForUpdatesWhenReady()
    }

    /// Check for updates using the custom popover-based UI.
    public func checkForUpdatesInCustomUI() {
        checkForUpdatesWhenReady()
    }

    private func performCheckForUpdates() {
        startUpdaterIfNeeded()
        ensureSparkleInstallationCache()
        // Cancel any pending deferred re-check on every path so a stale one can't fire a
        // duplicate checkForUpdates() after this new check starts.
        recheckTask?.cancel()
        if model.state == .idle {
            updater.checkForUpdates()
            return
        }

        model.cancelActiveStateForNewCheck()

        // Give Sparkle a beat to tear down the just-dismissed check session before starting a
        // new one. Without this delay the re-check is coalesced/dropped by Sparkle and the pill
        // simply hides until the user checks again (a real regression caught in dogfood). This
        // is a bounded, cancellable delay via the injected clock (matches the prior 100ms).
        recheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self.updater.checkForUpdates()
        }
    }

    /// Check for updates once the updater reports it can.
    private func checkForUpdatesWhenReady() {
        if isDevLikeBundle {
            // DEV/staging builds are not on the public release train. A manual check (menu,
            // custom UI, or attempt-and-install) must not query the public appcast or offer the
            // public release for install over a locally-built app. Surface "No Updates Available"
            // without contacting the appcast or starting Sparkle. This is the shared entrypoint
            // for every manual check path (#6292).
            log.append("manual update check suppressed (dev/staging build)")
            cancelReadinessRetry()
            model.setState(.notFound(.init(acknowledgement: {})))
            return
        }
        cancelReadinessRetry()
        startUpdaterIfNeeded()
        ensureSparkleInstallationCache()
        let canCheck = updater.canCheckForUpdates
        log.append("checkForUpdatesWhenReady invoked (canCheck=\(canCheck))")
        if canCheck {
            performCheckForUpdates()
            return
        }
        if model.state.isIdle {
            model.setState(.checking(.init(cancel: {})))
        }
        waitForReadinessThenCheck()
    }

    private func waitForReadinessThenCheck() {
        readyCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = self.readyRetryCount
            while remaining > 0 {
                if self.updater.canCheckForUpdates {
                    self.performCheckForUpdates()
                    return
                }
                remaining -= 1
                // Bounded readiness wait on the injected clock (see property comment).
                try? await self.clock.sleep(for: self.readyRetryDelay)
                if Task.isCancelled { return }
            }
            self.log.append("checkForUpdatesWhenReady timed out")
            if case .checking = self.model.state {
                self.model.setState(.error(.init(
                    error: NSError(
                        domain: "cmux.update",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "update.error.notReady", defaultValue: "Updater is still starting. Try again in a moment.")]
                    ),
                    retry: { [weak self] in self?.checkForUpdates() },
                    dismiss: { [weak self] in self?.model.setState(.idle) }
                )))
            }
        }
    }

    private func cancelReadinessRetry() {
        readyCheckTask?.cancel()
        readyCheckTask = nil
    }

    // MARK: - Updater lifecycle

    /// Start the updater. If startup fails, the error is shown via the custom UI.
    public func startUpdaterIfNeeded() {
        guard !didStartUpdater else { return }
        ensureSparkleInstallationCache()
#if DEBUG
        // Keep the permission-related defaults resettable for UI tests even though the
        // delegate now suppresses Sparkle's permission UI entirely.
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_RESET_SPARKLE_PERMISSION"] == "1" {
            defaults.removeObject(forKey: UpdateSettings.automaticChecksKey)
            defaults.removeObject(forKey: UpdateSettings.automaticallyUpdateKey)
            defaults.removeObject(forKey: UpdateSettings.scheduledCheckIntervalKey)
            defaults.removeObject(forKey: UpdateSettings.sendProfileInfoKey)
            defaults.removeObject(forKey: UpdateSettings.migrationKey)
            defaults.synchronize()
            log.append("reset sparkle permission defaults (ui test)")
        }
#endif
        if isDevLikeBundle {
            // Re-assert the dev/staging auto-check override immediately before Sparkle starts.
            // The init-time override can be cleared between construction and start — notably the
            // DEBUG reset path above removes this key — and Sparkle reads it at `start()` to decide
            // whether to schedule its own background checks against the public appcast (#6292).
            defaults.set(false, forKey: UpdateSettings.automaticChecksKey)
        }
        do {
            try updater.start()
            didStartUpdater = true
            let interval = Int(updater.updateCheckInterval.rounded())
            log.append(
                "updater started (autoChecks=\(updater.automaticallyChecksForUpdates), interval=\(interval)s, autoDownloads=\(updater.automaticallyDownloadsUpdates))"
            )
            startLaunchUpdateProbeIfNeeded()
        } catch {
            model.setState(.error(.init(
                error: error,
                retry: { [weak self] in
                    self?.model.setState(.idle)
                    self?.didStartUpdater = false
                    self?.startUpdaterIfNeeded()
                },
                dismiss: { [weak self] in
                    self?.model.setState(.idle)
                }
            )))
        }
    }

    private func startLaunchUpdateProbeIfNeeded() {
        if isDevLikeBundle {
            // DEV/staging builds are not on the public release train; never probe the public
            // appcast (init also disables Sparkle's own scheduled checks). Tear down any probe a
            // prior path may have started. See `isDevLikeBundleIdentifier(_:)` (#6292).
            log.append("launch update probe skipped (dev/staging build)")
            backgroundProbeTask?.cancel()
            backgroundProbeTask = nil
            return
        }
        guard updater.automaticallyChecksForUpdates else {
            log.append("launch update probe skipped (automatic checks disabled)")
            return
        }

        // Probe immediately on launch so the sidebar can surface a passive update indicator
        // without waiting for Sparkle's scheduled check or opening interactive update UI.
        log.append("starting launch update probe")
        updater.checkForUpdateInformation()

        // Re-probe periodically so the banner appears even if the app has been running for a
        // while when a new version is published. Genuine periodic schedule via the clock.
        backgroundProbeTask?.cancel()
        backgroundProbeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.backgroundProbeInterval else { return }
                try? await self?.clock.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                guard self.updater.automaticallyChecksForUpdates else { continue }
                self.log.append("periodic background update probe")
                self.updater.checkForUpdateInformation()
            }
        }
    }

    private func recordUITestTimestamp(key: String) {
#if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_MODE"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_TIMING_PATH"] else { return }

        let url = URL(fileURLWithPath: path)
        var payload: [String: Double] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            payload = object
        }
        payload[key] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: url)
        }
#endif
    }

    private func ensureSparkleInstallationCache() {
        guard let bundleIdentifier = hostBundle.bundleIdentifier else { return }
        guard let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }

        let baseURL = cachesURL
            .appendingPathComponent(bundleIdentifier)
            .appendingPathComponent("org.sparkle-project.Sparkle")
        let installURL = baseURL.appendingPathComponent("Installation")

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: installURL.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                do {
                    try fileManager.removeItem(at: installURL)
                } catch {
                    log.append("Failed removing Sparkle installation cache file: \(error)")
                    return
                }
            } else {
                return
            }
        }

        do {
            try fileManager.createDirectory(
                at: installURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            log.append("Ensured Sparkle installation cache at \(installURL.path)")
        } catch {
            log.append("Failed creating Sparkle installation cache: \(error)")
        }
    }
}

extension UpdateController {
    /// Whether `bundleIdentifier` is a cmux DEV (`com.cmuxterm.app.debug[.<tag>]`) or staging
    /// (`com.cmuxterm.app.staging[.<tag>]`) build.
    ///
    /// Such builds are produced from local source and are not on the public release train, so
    /// they must never be compared against the public Sparkle appcast (#6292).
    ///
    /// Mirrors `SocketControlSettings.isDebugLikeBundleIdentifier` +
    /// `isStagingBundleIdentifier` (in the CmuxSettings package). The classification is
    /// duplicated here deliberately to avoid introducing a `CmuxUpdater → CmuxSettings` package
    /// dependency edge for a small string check.
    static func isDevLikeBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.cmuxterm.app.debug"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.")
            || bundleIdentifier == "com.cmuxterm.app.staging"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.staging.")
    }
}
