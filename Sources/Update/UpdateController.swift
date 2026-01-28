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

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're force-installing an update.
    var isInstalling: Bool {
        installCancellable != nil
    }

    init() {
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
    }

    /// Start the updater. If startup fails, the error is shown via the custom UI.
    func startUpdater() {
        do {
            try updater.start()
        } catch {
            userDriver.viewModel.state = .error(.init(
                error: error,
                retry: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                    self?.startUpdater()
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
        let canCheck = updater.canCheckForUpdates
        UpdateLogStore.shared.append("checkForUpdatesWhenReady invoked (canCheck=\(canCheck))")
        if canCheck {
            checkForUpdates()
            return
        }
        guard retries > 0 else {
            UpdateLogStore.shared.append("checkForUpdatesWhenReady timed out")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkForUpdatesWhenReady(retries: retries - 1)
        }
    }

    /// Validate the check for updates menu item.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            return updater.canCheckForUpdates
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
}
