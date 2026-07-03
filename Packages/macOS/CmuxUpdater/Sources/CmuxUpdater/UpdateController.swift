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
    private let updater: any UpdaterHandle
    // `driver` and `log` are internal (not private) so `UpdateController+InstallAttempt.swift`
    // can reach them; they stay module-internal.
    let driver: UpdateDriver
    let log: any UpdateLogging
    private let clock: any UpdateClock
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let hostBundle: Bundle
    private let backgroundProbeInterval: TimeInterval
    /// Whether the running build is a cmux DEV/staging build that must never be compared against
    /// the public release appcast. See ``isDevLikeBundleIdentifier(_:)``.
    private let isDevLikeBundle: Bool

    /// Host actions the updater delegates upward (retry, relaunch prep). Forwarded to the driver.
    public weak var actionDelegate: (any UpdateActionDelegate)? {
        didSet { driver.actionDelegate = actionDelegate }
    }

    // Reaction state (replaces the Combine subscriptions).
    /// Sequences "re-resolve to the latest, then install" so the install path never installs the
    /// version that was captured when the prompt was first surfaced (issue #6366). Internal for
    /// `UpdateController+InstallAttempt.swift`.
    var attemptCoordinator = AttemptUpdateCoordinator()
    private var stateReactionTask: Task<Void, Never>?
    private var noUpdateDismissTask: Task<Void, Never>?
    private var backgroundProbeTask: Task<Void, Never>?
    private var recheckTask: Task<Void, Never>?
    /// Armed when the user asks to install; fires a visible "Update Didn't Start" error if the
    /// flow never reaches downloading/installing (or another visible outcome). See
    /// ``attemptUpdate`` in `UpdateController+InstallAttempt.swift` (internal for that file).
    let installWatchdog: InstallWatchdog

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
    public convenience init(log: any UpdateLogging,
                            clock: any UpdateClock = SystemUpdateClock(),
                            settings: UpdateSettings = UpdateSettings(),
                            hostBundle: Bundle = .main,
                            defaults: UserDefaults = .standard,
                            fileManager: FileManager = .default,
                            isDevLikeBundle: Bool? = nil) {
        self.init(log: log,
                  clock: clock,
                  settings: settings,
                  hostBundle: hostBundle,
                  defaults: defaults,
                  fileManager: fileManager,
                  isDevLikeBundle: isDevLikeBundle,
                  updaterFactory: { driver, hostBundle in
                      SPUUpdater(
                          hostBundle: hostBundle,
                          applicationBundle: hostBundle,
                          userDriver: driver,
                          delegate: driver
                      )
                  })
    }

    /// The designated initializer, with the updater seam exposed.
    ///
    /// - Parameter updaterFactory: Builds the ``UpdaterHandle`` from the freshly created driver
    ///   and host bundle. Production (the convenience init above) always builds a real
    ///   `SPUUpdater`; pipeline tests inject a fake so the reaction loop can be replayed
    ///   deterministically.
    init(log: any UpdateLogging,
         clock: any UpdateClock = SystemUpdateClock(),
         settings: UpdateSettings = UpdateSettings(),
         hostBundle: Bundle = .main,
         defaults: UserDefaults = .standard,
         fileManager: FileManager = .default,
         isDevLikeBundle: Bool? = nil,
         updaterFactory: (UpdateDriver, Bundle) -> any UpdaterHandle) {
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

        self.installWatchdog = InstallWatchdog(clock: clock, timeout: installWatchdogTimeout)
        let model = UpdateStateModel()
        let driver = UpdateDriver(model: model, log: log, clock: clock, isDevLikeBundle: isDevLikeBundle)
        self.driver = driver
        self.updater = updaterFactory(driver, hostBundle)
        startStateReactions()
    }

    deinit {
        stateReactionTask?.cancel()
        noUpdateDismissTask?.cancel()
        backgroundProbeTask?.cancel()
        readyCheckTask?.cancel()
        recheckTask?.cancel()
        // installWatchdog cancels its own pending timer in its deinit (it is released with self).
    }

    // MARK: - Reaction stream

    private func startStateReactions() {
        let changes = model.stateChanges()
        stateReactionTask = Task { @MainActor [weak self] in
            if let self {
                self.handleStateChange(self.model.state, overrideState: self.model.overrideState)
            }
            for await _ in changes {
                guard let self else { return }
                // Drain every recorded transition in order rather than re-reading the latest
                // state: two transitions landing before this task runs would otherwise conflate,
                // and a control-flow consumer (the attempt coordinator) could miss the
                // `.checking` restart signal entirely — the same ambiguity family as the
                // double-idle install loop.
                for change in self.model.drainPendingChanges() {
                    self.handleStateChange(change.state, overrideState: change.overrideState)
                }
            }
        }
    }

    /// Runs the three state reactions for one observed transition. Invoked once on start with
    /// the current model values and then for every drained ``UpdateStateChange``
    /// (the merge of the old `$state.sink`, the attempt sink, and the `CombineLatest` dismiss
    /// observer).
    private func handleStateChange(_ state: UpdateState, overrideState: UpdateState?) {

        if attemptCoordinator.isMonitoring {
            let action = attemptCoordinator.handleStateChange(state)
            // The watchdog guards one specific install attempt. If that attempt just ended
            // without handing an install to Sparkle (the user cancelled the fresh check, or it
            // terminated in notFound/error), disarm now so the leftover deadline can't fire a
            // spurious "Update Didn't Start" over a later, unrelated check. A `.confirmInstall`
            // hand-off keeps the deadline armed until a resolved state below disarms it.
            if installWatchdog.isArmed,
               installWatchdog.attemptEndedWithoutInstall(
                   action: action,
                   isCoordinatorMonitoring: attemptCoordinator.isMonitoring
               ) {
                installWatchdog.disarm()
            }
            performAttemptAction(action)
        }
        // Disarm the install watchdog the moment the flow progresses the install or shows a clear
        // outcome, so a healthy install (or a real error / "no updates") never trips it.
        if installWatchdog.isArmed, installWatchdog.installAttemptResolved(state) {
            installWatchdog.disarm()
        }
        scheduleNoUpdateDismiss(for: state, overrideState: overrideState)
    }

    // The attempt-update entry point, its coordinator actions, and the install-watchdog trip
    // handling live in `UpdateController+InstallAttempt.swift`.

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
        if model.state.isIdle, !attemptCoordinator.isMonitoring {
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
                        domain: UpdateStateModel.updateErrorDomain,
                        code: UpdateStateModel.updaterNotReadyCode,
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
