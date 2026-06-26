public import Foundation
@preconcurrency import Sparkle

/// Coordinates cmux's custom Sparkle update flow: owns the `SPUUpdater` and its
/// ``UpdateDriver``, exposes the observable ``UpdateStateModel``, and sequences the
/// user-facing actions (check, force-install, attempt-and-install).
///
/// The previous implementation observed the model's `@Published` state through Combine
/// (`$state.sink`, `Publishers.CombineLatest`). This version consumes the model's
/// ``UpdateStateModel/stateChanges()`` `AsyncStream` in one long-lived main-actor task and
/// runs the three reactions (force-install, attempt-update, "no updates" auto-dismiss) as
/// plain state-machine logic gated by flags. Bounded delays (and the updater-readiness wait)
/// use the injected ``UpdateClock``.
///
/// Construct one at app startup, set ``actionDelegate``, and inject it where the update menu
/// items and pill live. This is the package's composition surface; the app target supplies the
/// concrete ``UpdateLogging`` and ``UpdateActionDelegate``.
@MainActor
public final class UpdateController {
    private let updater: SPUUpdater
    private let driver: UpdateDriver
    private let log: any UpdateLogging
    private let clock: any UpdateClock
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let hostBundle: Bundle
    private let backgroundProbeInterval: TimeInterval

    /// Host actions the updater delegates upward (retry, relaunch prep). Forwarded to the driver.
    public weak var actionDelegate: (any UpdateActionDelegate)? {
        didSet { driver.actionDelegate = actionDelegate }
    }

    // Reaction state (replaces the Combine subscriptions).
    private var isForceInstalling = false
    private var isAttemptingUpdate = false
    private var didObserveAttemptUpdateProgress = false
    private var stateReactionTask: Task<Void, Never>?
    private var noUpdateDismissTask: Task<Void, Never>?
    private var backgroundProbeTask: Task<Void, Never>?
    private var recheckTask: Task<Void, Never>?

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

    /// Whether a force-install is in progress (auto-confirming each installable state).
    public var isInstalling: Bool { isForceInstalling }

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
    public init(log: any UpdateLogging,
                clock: any UpdateClock = SystemUpdateClock(),
                settings: UpdateSettings = UpdateSettings(),
                hostBundle: Bundle = .main,
                defaults: UserDefaults = .standard,
                fileManager: FileManager = .default) {
        self.log = log
        self.clock = clock
        self.defaults = defaults
        self.fileManager = fileManager
        self.hostBundle = hostBundle
        self.backgroundProbeInterval = settings.scheduledCheckInterval
        settings.apply(to: defaults)

        let model = UpdateStateModel()
        let driver = UpdateDriver(model: model, log: log, clock: clock)
        self.driver = driver
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: driver,
            delegate: driver
        )
        startStateReactions()
    }

    deinit {
        stateReactionTask?.cancel()
        noUpdateDismissTask?.cancel()
        backgroundProbeTask?.cancel()
        readyCheckTask?.cancel()
        recheckTask?.cancel()
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

        if isForceInstalling {
            evaluateForceInstall(state)
        }
        if isAttemptingUpdate {
            evaluateAttempt(state)
        }
        scheduleNoUpdateDismiss(for: state, overrideState: overrideState)
    }

    // MARK: - Force install

    /// Force install the current update by auto-confirming all installable states.
    public func installUpdate() {
        guard model.state.isInstallable else { return }
        guard !isForceInstalling else { return }
        isForceInstalling = true
        evaluateForceInstall(model.state)
    }

    private func evaluateForceInstall(_ state: UpdateState) {
        guard state.isInstallable else {
            isForceInstalling = false
            return
        }
        state.confirm()
    }

    // MARK: - Attempt update

    /// Check for updates and auto-confirm install if one is found.
    public func attemptUpdate() {
        stopAttemptUpdateMonitoring()
        didObserveAttemptUpdateProgress = false
        isAttemptingUpdate = true
        evaluateAttempt(model.state)
        checkForUpdates()
    }

    private func evaluateAttempt(_ state: UpdateState) {
        if state.isInstallable || !state.isIdle {
            didObserveAttemptUpdateProgress = true
        }

        if case .updateAvailable = state {
            log.append("attemptUpdate auto-confirming available update")
            state.confirm()
            return
        }

        // Only stop on terminal failure states (.notFound, .error). Don't stop on .idle —
        // the check may still be starting up (retry loop, background probe finishing).
        guard didObserveAttemptUpdateProgress, !state.isInstallable, !state.isIdle else {
            return
        }
        stopAttemptUpdateMonitoring()
    }

    private func stopAttemptUpdateMonitoring() {
        isAttemptingUpdate = false
        didObserveAttemptUpdateProgress = false
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

    /// Retry after a transient Sparkle download failure. Unlike a user-started fresh check,
    /// this preserves any in-progress install/attempt intent so a retried archive download can
    /// continue silently after Sparkle finds the same update again.
    public func retryAfterTransientFailure() {
        let shouldPreserveInstallIntent = isForceInstalling || isAttemptingUpdate
        log.append("retrying update after transient download failure (preserveInstallIntent=\(shouldPreserveInstallIntent))")
        checkForUpdatesWhenReady(preservingInstallIntent: shouldPreserveInstallIntent)
    }

    private func performCheckForUpdates(preservingInstallIntent: Bool = false) {
        startUpdaterIfNeeded()
        ensureSparkleInstallationCache()
        // Cancel any pending deferred re-check on every path so a stale one can't fire a
        // duplicate checkForUpdates() after this new check starts.
        recheckTask?.cancel()
        if preservingInstallIntent {
            updater.checkForUpdates()
            return
        }
        if model.state == .idle {
            updater.checkForUpdates()
            return
        }

        isForceInstalling = false
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
    private func checkForUpdatesWhenReady(preservingInstallIntent: Bool = false) {
        cancelReadinessRetry()
        startUpdaterIfNeeded()
        ensureSparkleInstallationCache()
        let canCheck = updater.canCheckForUpdates
        log.append("checkForUpdatesWhenReady invoked (canCheck=\(canCheck))")
        if canCheck {
            performCheckForUpdates(preservingInstallIntent: preservingInstallIntent)
            return
        }
        if model.state.isIdle {
            model.setState(.checking(.init(cancel: {})))
        }
        waitForReadinessThenCheck(preservingInstallIntent: preservingInstallIntent)
    }

    private func waitForReadinessThenCheck(preservingInstallIntent: Bool = false) {
        readyCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = self.readyRetryCount
            while remaining > 0 {
                if self.updater.canCheckForUpdates {
                    self.performCheckForUpdates(preservingInstallIntent: preservingInstallIntent)
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
