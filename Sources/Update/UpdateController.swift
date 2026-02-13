import Sparkle
import Cocoa
import Combine
import SwiftUI

/// Controller for managing Sparkle updates in cmuxterm.
class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver
    private var installCancellable: AnyCancellable?
    private var noUpdateDismissCancellable: AnyCancellable?
    private var noUpdateDismissWorkItem: DispatchWorkItem?
    private var readyCheckWorkItem: DispatchWorkItem?
    private var didStartUpdater: Bool = false
    private let readyRetryDelay: TimeInterval = 0.25
    private let readyRetryCount: Int = 20

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're force-installing an update.
    var isInstalling: Bool {
        installCancellable != nil
    }

    init() {
        // Default to manual update checks. This also prevents Sparkle from prompting at startup.
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "SUEnableAutomaticChecks": false,
            "SUSendProfileInfo": false,
            "SUAutomaticallyUpdate": false,
        ])

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
        noUpdateDismissCancellable?.cancel()
        noUpdateDismissWorkItem?.cancel()
        readyCheckWorkItem?.cancel()
    }

    /// Start the updater. If startup fails, the error is shown via the custom UI.
    func startUpdaterIfNeeded() {
        guard !didStartUpdater else { return }
        ensureSparkleInstallationCache()
#if DEBUG
        // UI tests need to exercise Sparkle's permission request deterministically.
        // Clearing these defaults causes Sparkle to re-request permission on next start.
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_RESET_SPARKLE_PERMISSION"] == "1" {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "SUEnableAutomaticChecks")
            defaults.removeObject(forKey: "SUSendProfileInfo")
            defaults.removeObject(forKey: "SUAutomaticallyUpdate")
            defaults.synchronize()
            UpdateLogStore.shared.append("reset sparkle permission defaults (ui test)")
        }
#endif
        do {
            // cmuxterm never enables automatic update checks; we rely on the in-app update pill.
            // Sparkle reads these from defaults, but set them explicitly before starting.
            let defaults = UserDefaults.standard
            defaults.set(false, forKey: "SUEnableAutomaticChecks")
            defaults.set(false, forKey: "SUSendProfileInfo")
            defaults.set(false, forKey: "SUAutomaticallyUpdate")

            try updater.start()
            didStartUpdater = true
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

    /// Check for updates (used by the menu item).
    @objc func checkForUpdates() {
        UpdateLogStore.shared.append("checkForUpdates invoked (state=\(viewModel.state.isIdle ? "idle" : "busy"))")
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
                        domain: "cmuxterm.update",
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
            // Always allow user-initiated checks; we start Sparkle lazily on first use.
            return true
        }
        return true
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
