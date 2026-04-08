import Sparkle
import Cocoa
import Combine
import SwiftUI

enum UpdateSettings {
    static let automaticChecksKey = "SUEnableAutomaticChecks"
    static let automaticallyUpdateKey = "SUAutomaticallyUpdate"
    static let scheduledCheckIntervalKey = "SUScheduledCheckInterval"
    static let sendProfileInfoKey = "SUSendProfileInfo"
    static let migrationKey = "cmux.sparkle.automaticChecksMigration.v2"
    static let previousDefaultScheduledCheckInterval: TimeInterval = 60 * 60 * 24
    static let scheduledCheckInterval: TimeInterval = 60 * 60

    static func apply(to defaults: UserDefaults) {
        defaults.register(defaults: [
            automaticChecksKey: true,
            automaticallyUpdateKey: false,
            scheduledCheckIntervalKey: scheduledCheckInterval,
            sendProfileInfoKey: false,
        ])

        guard !defaults.bool(forKey: migrationKey) else { return }

        // Repair older installs that may have ended up with automatic checks disabled
        // before the updater defaults were embedded in Info.plist.
        defaults.set(true, forKey: automaticChecksKey)

        if let interval = defaults.object(forKey: scheduledCheckIntervalKey) as? NSNumber {
            let currentInterval = interval.doubleValue
            if currentInterval <= 0 ||
                abs(currentInterval - previousDefaultScheduledCheckInterval) < 1 {
                defaults.set(scheduledCheckInterval, forKey: scheduledCheckIntervalKey)
            }
        } else {
            defaults.set(scheduledCheckInterval, forKey: scheduledCheckIntervalKey)
        }

        if defaults.object(forKey: automaticallyUpdateKey) == nil {
            defaults.set(false, forKey: automaticallyUpdateKey)
        }
        if defaults.object(forKey: sendProfileInfoKey) == nil {
            defaults.set(false, forKey: sendProfileInfoKey)
        }

        defaults.set(true, forKey: migrationKey)
    }
}

/// Controller for managing Sparkle updates in cmux.
class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver
    private var installCancellable: AnyCancellable?
    private var attemptInstallCancellable: AnyCancellable?
    private var didObserveAttemptUpdateProgress: Bool = false
    private var noUpdateDismissCancellable: AnyCancellable?
    private var noUpdateDismissWorkItem: DispatchWorkItem?
    private var readyCheckWorkItem: DispatchWorkItem?
    private var backgroundProbeTimer: Timer?
    private var didStartUpdater: Bool = false
    private let readyRetryDelay: TimeInterval = 0.25
    private let readyRetryCount: Int = 20
    private let backgroundProbeInterval: TimeInterval = UpdateSettings.scheduledCheckInterval

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're force-installing an update.
    var isInstalling: Bool {
        installCancellable != nil
    }

    init() {
        let defaults = UserDefaults.standard
        UpdateSettings.apply(to: defaults)

        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(viewModel: .init(), hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: userDriver
        )
        installNoUpdateDismissObserver()
    }

    deinit {
        installCancellable?.cancel()
        attemptInstallCancellable?.cancel()
        noUpdateDismissCancellable?.cancel()
        noUpdateDismissWorkItem?.cancel()
        readyCheckWorkItem?.cancel()
        backgroundProbeTimer?.invalidate()
    }

    /// Start the updater. If startup fails, the error is shown via the custom UI.
    func startUpdaterIfNeeded() {
        guard !didStartUpdater else { return }
        ensureSparkleInstallationCache()
#if DEBUG
        // Keep the permission-related defaults resettable for UI tests even though the
        // delegate now suppresses Sparkle's permission UI entirely.
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_RESET_SPARKLE_PERMISSION"] == "1" {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: UpdateSettings.automaticChecksKey)
            defaults.removeObject(forKey: UpdateSettings.automaticallyUpdateKey)
            defaults.removeObject(forKey: UpdateSettings.scheduledCheckIntervalKey)
            defaults.removeObject(forKey: UpdateSettings.sendProfileInfoKey)
            defaults.removeObject(forKey: UpdateSettings.migrationKey)
            defaults.synchronize()
            UpdateLogStore.shared.append("reset sparkle permission defaults (ui test)")
        }
#endif
        do {
            try updater.start()
            didStartUpdater = true
            let interval = Int(updater.updateCheckInterval.rounded())
            UpdateLogStore.shared.append(
                "updater started (autoChecks=\(updater.automaticallyChecksForUpdates), interval=\(interval)s, autoDownloads=\(updater.automaticallyDownloadsUpdates))"
            )
            startLaunchUpdateProbeIfNeeded()
        } catch {
            userDriver.viewModel.state = .error(.init(
                error: error,
                retry: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                    self?.didStartUpdater = false
                    self?.startUpdaterIfNeeded()
                },
                dismiss: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                }
            ))
        }
    }

    private func startLaunchUpdateProbeIfNeeded() {
        guard updater.automaticallyChecksForUpdates else {
            UpdateLogStore.shared.append("launch update probe skipped (automatic checks disabled)")
            return
        }

        // Probe immediately on launch so the sidebar can surface a passive update indicator
        // without waiting for Sparkle's scheduled check or opening interactive update UI.
        UpdateLogStore.shared.append("starting launch update probe")
        updater.checkForUpdateInformation()

        // Re-probe every hour so the banner appears even if the app has been running
        // for a while when a new version is published.
        backgroundProbeTimer?.invalidate()
        backgroundProbeTimer = Timer.scheduledTimer(withTimeInterval: backgroundProbeInterval, repeats: true) { [weak self] _ in
            guard let self, self.updater.automaticallyChecksForUpdates else { return }
            UpdateLogStore.shared.append("periodic background update probe")
            self.updater.checkForUpdateInformation()
        }
    }

    /// Force install the current update by auto-confirming all installable states.
    func installUpdate() {
        guard viewModel.state.isInstallable else { return }
        guard installCancellable == nil else { return }

        installCancellable = viewModel.$state.sink { [weak self] state in
            guard let self else { return }
            guard state.isInstallable else {
                self.installCancellable = nil
                return
            }
            state.confirm()
        }
    }

    /// Check for updates and auto-confirm install if one is found.
    func attemptUpdate() {
        stopAttemptUpdateMonitoring()
        didObserveAttemptUpdateProgress = false

        attemptInstallCancellable = viewModel.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }

                if state.isInstallable || !state.isIdle {
                    self.didObserveAttemptUpdateProgress = true
                }

                if case .updateAvailable = state {
                    UpdateLogStore.shared.append("attemptUpdate auto-confirming available update")
                    state.confirm()
                    return
                }

                // Only stop on terminal failure states (.notFound, .error).
                // Don't stop on .idle — the check may still be starting up
                // (e.g. retry loop, background probe finishing).
                guard self.didObserveAttemptUpdateProgress, !state.isInstallable, !state.isIdle else {
                    return
                }
                self.stopAttemptUpdateMonitoring()
            }

        checkForUpdates()
    }

    /// Check for updates (used by the menu item).
    @objc func checkForUpdates() {
        UpdateLogStore.shared.append("checkForUpdates invoked (state=\(viewModel.state.isIdle ? "idle" : "busy"))")
        checkForUpdatesWhenReady(retries: readyRetryCount)
    }

    /// Check for updates using the custom popover-based UI.
    func checkForUpdatesInCustomUI() {
        checkForUpdatesWhenReady(retries: readyRetryCount)
    }

    private func performCheckForUpdates() {
        startUpdaterIfNeeded()
        ensureSparkleInstallationCache()
        if viewModel.state == .idle {
            updater.checkForUpdates()
            return
        }

        installCancellable?.cancel()
        viewModel.state.cancel()

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.updater.checkForUpdates()
        }
    }

    /// Check for updates once the updater is ready (used by UI tests).
    func checkForUpdatesWhenReady(retries: Int = 10) {
        readyCheckWorkItem?.cancel()
        readyCheckWorkItem = nil
        startUpdaterIfNeeded()
        ensureSparkleInstallationCache()
        let canCheck = updater.canCheckForUpdates
        UpdateLogStore.shared.append("checkForUpdatesWhenReady invoked (canCheck=\(canCheck))")
        if canCheck {
            performCheckForUpdates()
            return
        }
        if viewModel.state.isIdle {
            viewModel.state = .checking(.init(cancel: {}))
        }
        guard retries > 0 else {
            UpdateLogStore.shared.append("checkForUpdatesWhenReady timed out")
            if case .checking = viewModel.state {
                viewModel.state = .error(.init(
                    error: NSError(
                        domain: "cmux.update",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Updater is still starting. Try again in a moment."]
                    ),
                    retry: { [weak self] in self?.checkForUpdates() },
                    dismiss: { [weak self] in self?.viewModel.state = .idle }
                ))
            }
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.checkForUpdatesWhenReady(retries: retries - 1)
        }
        readyCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + readyRetryDelay, execute: workItem)
    }

    /// Validate the check for updates menu item.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            // Always allow user-initiated checks; Sparkle can safely surface current progress.
            return true
        }
        return true
    }

    private func stopAttemptUpdateMonitoring() {
        attemptInstallCancellable?.cancel()
        attemptInstallCancellable = nil
        didObserveAttemptUpdateProgress = false
    }

    private func installNoUpdateDismissObserver() {
        noUpdateDismissCancellable = Publishers.CombineLatest(viewModel.$state, viewModel.$overrideState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, overrideState in
                self?.scheduleNoUpdateDismiss(for: state, overrideState: overrideState)
            }
    }

    private func scheduleNoUpdateDismiss(for state: UpdateState, overrideState: UpdateState?) {
        noUpdateDismissWorkItem?.cancel()
        noUpdateDismissWorkItem = nil

        guard overrideState == nil else { return }
        guard case .notFound(let notFound) = state else { return }

        recordUITestTimestamp(key: "noUpdateShownAt")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.viewModel.overrideState == nil,
                  case .notFound = self.viewModel.state else { return }

            withAnimation(.easeInOut(duration: 0.25)) {
                self.recordUITestTimestamp(key: "noUpdateHiddenAt")
                self.viewModel.state = .idle
            }
            notFound.acknowledgement()
        }
        noUpdateDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + UpdateTiming.noUpdateDisplayDuration,
            execute: workItem
        )
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
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }

        let baseURL = cachesURL
            .appendingPathComponent(bundleIdentifier)
            .appendingPathComponent("org.sparkle-project.Sparkle")
        let installURL = baseURL.appendingPathComponent("Installation")

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: installURL.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                do {
                    try FileManager.default.removeItem(at: installURL)
                } catch {
                    UpdateLogStore.shared.append("Failed removing Sparkle installation cache file: \(error)")
                    return
                }
            } else {
                return
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: installURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            UpdateLogStore.shared.append("Ensured Sparkle installation cache at \(installURL.path)")
        } catch {
            UpdateLogStore.shared.append("Failed creating Sparkle installation cache: \(error)")
        }
    }
}
